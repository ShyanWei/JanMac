#!/usr/bin/env bash
# Build Jan (v0.8.8 + the budget/steps/context patch) for Apple Silicon, on a Mac.
#
# Prerequisites on the machine:
#   - Xcode + Command Line Tools   (xcode-select --install)
#   - cmake                        (brew install cmake)
#   - Node 22+                     (corepack ships with it)
#   - Rust                         (rustup; the aarch64 target is added below)
#
# Usage:
#   PATCH=/path/to/configurable-cowork-token-budget.patch bash build-mac-nightly.sh [dir]
#
# Result:
#   src-tauri/target/aarch64-apple-darwin/release/bundle/macos/*.app
#   src-tauri/target/aarch64-apple-darwin/release/bundle/dmg/*.dmg
#
# MLX is not bundled (its build needs a separate xcodebuild of mlx-swift);
# llama.cpp with Metal is built and bundled, so local inference still works.
set -euo pipefail

REPO_DIR="${1:-jan-patched}"
VERSION="${VERSION:-0.8.8-5712}"
PATCH_FILE="${PATCH:-}"
JAN_ENGINE_VARIANT="${JAN_ENGINE_VARIANT:-metal}"

if [[ -z "$PATCH_FILE" || ! -f "$PATCH_FILE" ]]; then
  echo "Set PATCH=/path/to/configurable-cowork-token-budget.patch" >&2
  exit 1
fi

command -v cargo >/dev/null || { echo "Install Rust first (rustup)." >&2; exit 1; }
command -v cmake >/dev/null || { echo "Install cmake (brew install cmake)." >&2; exit 1; }

git clone --branch v0.8.8 --depth 1 https://github.com/janhq/jan "$REPO_DIR"
cd "$REPO_DIR"

git apply "$PATCH_FILE"
echo "patch applied: $(git diff --stat | tail -1)"

corepack enable >/dev/null 2>&1 || true
corepack prepare yarn@4.5.3 --activate

# Nightly identity + version-with-hyphen (this is what enables Cowork). The
# script edits files by relative path, and the Jan checkout has no tools/
# directory, so run it from here by absolute path rather than copying it in.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANNEL_SCRIPT="${CHANNEL_SCRIPT:-$SCRIPT_DIR/mac-nightly-channel.mjs}"
node "$CHANNEL_SCRIPT" --version "$VERSION"

rustup target add aarch64-apple-darwin
command -v cmake >/dev/null || brew install cmake

yarn config set -H enableImmutableInstalls false
yarn install --no-immutable
yarn build:tauri:plugin:api
yarn build:core
yarn build:extensions

# bun + uv + sqlite-vec for darwin/arm64.
yarn download:bin

# The engine worker and the ggml dylibs the dmg bundles.
make build-engine JAN_ENGINE_VARIANT="$JAN_ENGINE_VARIANT"

# The nightly icon, same file Jan's own CI copies before `tauri icon`.
cp .github/scripts/icon-nightly.png src-tauri/icons/icon.png
yarn build:icon
yarn copy:assets:tauri

yarn tauri build --target aarch64-apple-darwin --bundles app,dmg

echo
echo "Artifacts:"
ls -lh src-tauri/target/aarch64-apple-darwin/release/bundle/macos/ 2>/dev/null || true
ls -lh src-tauri/target/aarch64-apple-darwin/release/bundle/dmg/ 2>/dev/null || true
