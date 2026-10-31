#!/usr/bin/env bash
# Prepares the macOS engine toolchain for `make build-engine`. Run from the Jan
# repo root, after `make engine-source`:
#     bash tools/mac-engine-toolchain.sh [explicit-Xcode-version]
#
# Why this exists: ggml's apple_m4 CPU backend variant is declared in
# ggml/src/CMakeLists.txt as `apple_m4 DOTPROD MATMUL_INT8 NOSVE SME`, which
# ggml-cpu/CMakeLists.txt turns into
#     -march=armv9.2-a+dotprod+i8mm+nosve+sme
# and ggml/src/ggml-cpu/vec.h calls svexpa_f32 -- an SVE intrinsic -- inside
# exp_ps_sve(), which is guarded by `#if defined(__ARM_FEATURE_SVE)`. Older
# AppleClang (15 = Xcode 15.4, the macos-14 image default) lets `+sme` define
# __ARM_FEATURE_SVE while `+nosve` still removes the *target feature*, so the
# path gets parsed and the engine build dies at ~95% with
#     vec.h:1100:26: error: 'svexpa_f32' needs target feature sve
# Newer AppleClang honours `+nosve` and compiles it as upstream wrote it, which
# is why Jan's own release CI pins Xcode 26.x.
#
# The gate below must therefore test exactly that construct: __ARM_FEATURE_SVE
# defined, svexpa_f32(svuint32_t) used in a non-streaming function. (A gate that
# merely mentions svexpa_f32 is wrong: passing it an svfloat32_t, or using SVE
# types without the guard, fails on *every* toolchain -- including the ones that
# build the engine fine -- and this script then patches and finally gives up
# even when nothing needed patching.)
#
# Strategy, cheapest first:
#   1. current toolchain compiles the upstream flags   -> nothing to do
#   2. newest installed Xcode that compiles them       -> switch xcode-select
#   3. patch the vendored cmake: '+nosve' -> '+sve'. armv9.2-a mandates SVE2
#      anyway, and the module is chosen at runtime only when SME is present
#      (M4 and later), which also has SVE; dispatch logic and the other
#      variants are untouched.
#   4. still no luck (a toolchain that cannot compile SVE intrinsics at all, or
#      does not know `+sme`): drop the apple_m4 variant from the vendored cmake
#      so the build finishes. The package then has no ggml-cpu-apple_m4 module;
#      Metal and the other CPU variants are unaffected.
set -uo pipefail

WANT="${1:-}"
VENDOR="src-tauri/plugins/tauri-plugin-llamacpp/vendor/llama.cpp"
CPU_CMAKE="$VENDOR/ggml/src/ggml-cpu/CMakeLists.txt"
SRC_CMAKE="$VENDOR/ggml/src/CMakeLists.txt"
UPSTREAM_FLAGS="-march=armv9.2-a+dotprod+i8mm+nosve+sme"
PATCHED_FLAGS="-march=armv9.2-a+dotprod+i8mm+sve+sme"

workdir=$(mktemp -d "${TMPDIR:-/tmp}/ggml-m4-gate.XXXXXX") || exit 1
probe="$workdir/probe.cpp"
cat > "$probe" <<'CPP'
// What the apple_m4 variant actually compiles, reduced to the construct that
// breaks: vec.h's exp_ps_sve() is a plain (non-streaming) inline function, it
// is compiled only when __ARM_FEATURE_SVE is defined, and it calls
// svexpa_f32() on an svuint32_t.
#include <arm_sme.h>
#include <arm_sve.h>

#if defined(__ARM_FEATURE_SVE)
__attribute__((used)) static svfloat32_t exp_ps_sve(svbool_t pg, svfloat32_t src) {
    const svuint32_t v = svlsr_n_u32_m(pg, svreinterpret_u32_f32(src), 17);
    return svadd_f32_x(pg, svexpa_f32(v), src);
}
__attribute__((used)) static float gate_sve(float x) {
    return svaddv_f32(svptrue_b32(), exp_ps_sve(svptrue_b32(), svdup_n_f32(x)));
}
#endif

#if defined(__ARM_FEATURE_SME)
// The variant really is compiled with +sme; smstart/smstop only assemble if the
// toolchain knows SME. Deliberately no streaming intrinsics: this gate must not
// reject a toolchain that vec.h does not actually need.
__attribute__((used)) static float gate_sme(void) {
    __asm__ volatile("smstart; smstop;");
    return 0.0f;
}
#endif

int main(void) {
    float r = 0.0f;
#if defined(__ARM_FEATURE_SVE)
    r += gate_sve(1.0f);
#endif
#if defined(__ARM_FEATURE_SME)
    r += gate_sme();
#endif
    return (int) r;
}
CPP

last_err=""
gate() {
  local log="$workdir/err.txt"
  if clang++ "$1" -fsyntax-only "$probe" 2>"$log"; then
    last_err=""
    return 0
  fi
  last_err=$(grep -m2 'error:' "$log" | sed 's/^/      /')
  return 1
}

show() {
  echo "  $(xcodebuild -version 2>/dev/null | head -1)"
  echo "  $(clang --version 2>/dev/null | head -1)"
}
# The compiler's own words, so a failure here is diagnosable from the CI log
# without re-running anything.
report_err() {
  if [ -n "$last_err" ]; then printf '%s\n' "$last_err"; fi
}
use_xcode() { sudo xcode-select -s "$1" >/dev/null 2>&1; }
ORIGINAL_DEV=$(xcode-select -p 2>/dev/null || echo "")

if [ -n "$WANT" ]; then
  dev="/Applications/Xcode_${WANT}.app/Contents/Developer"
  if [ ! -d "$dev" ]; then
    echo "error: Xcode_${WANT} is not installed on this machine. Available:" >&2
    ls -d /Applications/Xcode*.app >&2 2>/dev/null || echo "  (none)" >&2
    exit 1
  fi
  if ! use_xcode "$dev"; then
    echo "error: could not select $dev (xcode-select needs sudo)" >&2
    exit 1
  fi
  echo "engine toolchain: Xcode ${WANT} selected (explicit)"
  show
  if gate "$UPSTREAM_FLAGS"; then
    echo "engine toolchain: apple_m4 variant flags compile as upstream wrote them"
    exit 0
  fi
  echo "engine toolchain: they do not compile, falling back to the vendored cmake patches below"
  report_err
elif gate "$UPSTREAM_FLAGS"; then
  echo "engine toolchain: current toolchain already compiles the apple_m4 variant"
  show
  exit 0
else
  echo "engine toolchain: current toolchain cannot compile 'svexpa_f32' with $UPSTREAM_FLAGS"
  show
  report_err
  picked=""
  # Newest first: sort -V on "/Applications/Xcode_16.4.app"-style names.
  for x in $(ls -d /Applications/Xcode_*.app 2>/dev/null | sort -V -r); do
    if use_xcode "$x/Contents/Developer" && gate "$UPSTREAM_FLAGS"; then
      picked="$x"
      break
    fi
  done
  if [ -n "$picked" ]; then
    echo "engine toolchain: switched to $picked, which compiles the apple_m4 variant"
    show
    exit 0
  fi
  # Nothing worked: go back to whatever the image had selected rather than
  # leaving the last (oldest) Xcode we probed.
  if [ -n "$ORIGINAL_DEV" ]; then
    use_xcode "$ORIGINAL_DEV" || true
  fi
  echo "engine toolchain: no installed Xcode compiles it; patching the vendored cmake"
  show
  report_err
fi

[ -f "$CPU_CMAKE" ] || {
  echo "error: $CPU_CMAKE not found -- run 'make engine-source' first" >&2
  exit 1
}
# The tag is assembled in ggml_add_cpu_backend_variant_impl:
#     if (GGML_INTERNAL_NOSVE)
#         set(ARCH_TAGS "${ARCH_TAGS}+nosve")
# and apple_m4 is the only Apple variant that asks for NOSVE, so there is
# exactly one line to change. Refuse rather than guess if that ever changes.
found=$(grep -c '"${ARCH_TAGS}+nosve"' "$CPU_CMAKE")
if [ "$found" != "1" ]; then
  echo "error: expected exactly one '+nosve' tag line in $CPU_CMAKE, found $found." >&2
  echo "       The vendored ggml changed; update this fallback." >&2
  exit 1
fi
sed -i '' 's|"${ARCH_TAGS}+nosve"|"${ARCH_TAGS}+sve"|' "$CPU_CMAKE"
grep -n -A1 'GGML_INTERNAL_NOSVE' "$CPU_CMAKE" | head -4

if gate "$PATCHED_FLAGS"; then
  echo "engine toolchain: patched variant compiles ($PATCHED_FLAGS)"
  exit 0
fi

# Last resort: this toolchain cannot compile SVE intrinsics at all (or does not
# know `+sme`), so no flag combination can build the variant. Drop it and put
# the cmake back the way upstream wrote it.
echo "engine toolchain: even with '+sve' this toolchain rejects svexpa_f32; dropping the apple_m4 CPU variant"
report_err
[ -f "$SRC_CMAKE" ] || {
  echo "error: $SRC_CMAKE not found -- the vendored ggml layout changed" >&2
  exit 1
}
found=$(grep -c 'ggml_add_cpu_backend_variant(apple_m4' "$SRC_CMAKE")
if [ "$found" != "1" ]; then
  echo "error: expected exactly one 'ggml_add_cpu_backend_variant(apple_m4' line in" >&2
  echo "       $SRC_CMAKE, found $found. The vendored ggml changed; update this fallback," >&2
  echo "       or run the build on a newer Xcode (inputs.xcode, e.g. 16.4 or 26.x)." >&2
  exit 1
fi
sed -i '' '/ggml_add_cpu_backend_variant(apple_m4/d' "$SRC_CMAKE"
sed -i '' 's|"${ARCH_TAGS}+sve"|"${ARCH_TAGS}+nosve"|' "$CPU_CMAKE"
grep -n 'apple_m' "$SRC_CMAKE" | head -4
echo "warning: the package will contain no ggml-cpu-apple_m4 module. On M4+ the CPU" \
     "fallback uses ggml-cpu-apple_m2_m3; Metal and the other variants are unchanged."
echo "engine toolchain: ok (apple_m4 variant removed)"
