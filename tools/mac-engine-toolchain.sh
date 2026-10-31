#!/usr/bin/env bash
# Prepares the macOS engine toolchain for `make build-engine`. Run from the Jan
# repo root, after `make engine-source`:
#     bash tools/mac-engine-toolchain.sh [explicit-Xcode-version]
#
# Why this exists: ggml's apple_m4 CPU backend variant is compiled with
#     -march=armv9.2-a+dotprod+i8mm+nosve+sme
# and ggml/src/ggml-cpu/vec.h calls svexpa_f32 -- an SVE intrinsic -- inside the
# SME path. AppleClang 15 (Xcode 15.4, the macos-14 image default) does not treat
# `+sme` as implying `+sve`, so the engine build dies at ~95% with
#     vec.h:1100:26: error: 'svexpa_f32' needs target feature sve
# Newer AppleClang does, which is why Jan's own release CI pins Xcode 26.x.
#
# So: prefer a toolchain that compiles the flags as upstream wrote them, and only
# when none is installed drop the `+nosve` tag from the *vendored* ggml cmake.
# armv9.2-a already carries SVE, and that module is chosen at runtime only when
# SME is present (M4 and later), which also has SVE -- so the dispatch logic and
# the other variants are untouched.
set -uo pipefail

WANT="${1:-}"
CMAKE_FILE="src-tauri/plugins/tauri-plugin-llamacpp/vendor/llama.cpp/ggml/src/ggml-cpu/CMakeLists.txt"
M4_FLAGS="-march=armv9.2-a+dotprod+i8mm+nosve+sme"
M4_FLAGS_PATCHED="-march=armv9.2-a+dotprod+i8mm+sme"

probe=/tmp/ggml-m4-gate.cpp
cat > "$probe" <<'CPP'
#include <arm_sve.h>
void probe(void) {
  svfloat32_t t = svdup_f32(0.0f);
  (void)svexpa_f32(t);
}
CPP

gate() { clang++ "$1" -fsyntax-only "$probe" >/dev/null 2>&1; }
show() {
  echo "  $(xcodebuild -version 2>/dev/null | head -1)"
  echo "  $(clang --version 2>/dev/null | head -1)"
}
ORIGINAL_DEV=$(xcode-select -p 2>/dev/null || echo "")

if [ -n "$WANT" ]; then
  dev="/Applications/Xcode_${WANT}.app/Contents/Developer"
  if [ ! -d "$dev" ]; then
    echo "error: Xcode_${WANT} is not installed on this machine. Available:" >&2
    ls -d /Applications/Xcode*.app >&2 2>/dev/null || echo "  (none)" >&2
    exit 1
  fi
  sudo xcode-select -s "$dev"
  echo "engine toolchain: Xcode ${WANT} selected (explicit)"
  show
  if gate "$M4_FLAGS"; then
    echo "engine toolchain: apple_m4 variant flags compile as upstream wrote them"
    exit 0
  fi
  echo "engine toolchain: they do not compile, falling back to the +nosve patch below"
elif gate "$M4_FLAGS"; then
  echo "engine toolchain: current toolchain already compiles the apple_m4 variant"
  show
  exit 0
else
  echo "engine toolchain: current toolchain cannot compile 'svexpa_f32' with $M4_FLAGS"
  show
  picked=""
  # Newest first: sort -V on "/Applications/Xcode_16.4.app"-style names.
  for x in $(ls -d /Applications/Xcode_*.app 2>/dev/null | sort -V -r); do
    sudo xcode-select -s "$x/Contents/Developer" >/dev/null 2>&1 || continue
    if gate "$M4_FLAGS"; then
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
    sudo xcode-select -s "$ORIGINAL_DEV" >/dev/null 2>&1 || true
  fi
  echo "engine toolchain: no installed Xcode compiles it; patching the vendored cmake"
  show
fi

[ -f "$CMAKE_FILE" ] || {
  echo "error: $CMAKE_FILE not found -- run 'make engine-source' first" >&2
  exit 1
}
# The tag is assembled in ggml_add_cpu_backend_variant_impl:
#     if (GGML_INTERNAL_NOSVE)
#         set(ARCH_TAGS "${ARCH_TAGS}+nosve")
# and apple_m4 is the only Apple variant that asks for NOSVE, so there is
# exactly one line to change. Refuse rather than guess if that ever changes.
found=$(grep -c '"${ARCH_TAGS}+nosve"' "$CMAKE_FILE")
if [ "$found" != "1" ]; then
  echo "error: expected exactly one '+nosve' tag line in $CMAKE_FILE, found $found." >&2
  echo "       The vendored ggml changed; update this fallback." >&2
  exit 1
fi
sed -i '' 's|"${ARCH_TAGS}+nosve"|"${ARCH_TAGS}"|' "$CMAKE_FILE"
grep -n -A1 'GGML_INTERNAL_NOSVE' "$CMAKE_FILE" | head -4

if gate "$M4_FLAGS_PATCHED"; then
  echo "engine toolchain: patched variant compiles ($M4_FLAGS_PATCHED)"
else
  echo "error: even without '+nosve' this toolchain rejects svexpa_f32." >&2
  echo "       Run the build on a newer Xcode (inputs.xcode, e.g. 16.4 or 26.2)." >&2
  exit 1
fi
