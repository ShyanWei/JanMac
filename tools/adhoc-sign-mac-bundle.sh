#!/usr/bin/env bash
# Ad-hoc signs the Tauri .app and rewrites the .dmg around the signed copy.
# Run from the Jan repo root, after `yarn tauri build --bundles app,dmg`:
#     bash tools/adhoc-sign-mac-bundle.sh [bundle-dir]
#
# Why this exists: without a Developer ID Tauri leaves the bundle unsigned --
# there is no Contents/_CodeSignature -- while the nested Mach-O files keep the
# linker's own ad-hoc signature (`flags=0x20002(adhoc,linker-signed)`). That is
# a half-signed bundle: `codesign --verify --deep --strict` says
#     code has no resources but signature indicates they must be present
# and a quarantined download of it is what macOS 15/26 reports as
#     "Jan-nightly.app is damaged and can't be opened"
# Signing nested files first and the bundle last seals it. The dmg has to be
# rebuilt because tauri wrote it before anything was signed -- it copies files
# into the image, so signing afterwards would not survive.
#
# The result is still unsigned by Apple standards (no Developer ID, no
# notarization), so the first open still needs the quarantine attribute
# removed or right-click -> Open. What changes is that the bundle no longer
# looks corrupt, and `codesign --verify` passes.
set -euo pipefail

BUNDLE_DIR="${1:-src-tauri/target/aarch64-apple-darwin/release/bundle}"

APP=$(ls -d "$BUNDLE_DIR/macos/"*.app 2>/dev/null | head -1)
DMG=$(ls "$BUNDLE_DIR/dmg/"*.dmg 2>/dev/null | head -1)
if [ -z "$APP" ]; then
  echo "error: no .app under $BUNDLE_DIR/macos -- run 'yarn tauri build' first" >&2
  exit 1
fi

echo "signing: $APP"
# Nested Mach-O files first (dylibs, the .so backend modules, the engine
# worker, bundled bun/uv), then the bundle itself. Identifying by file type
# rather than by extension keeps this working when ggml renames its modules.
while IFS= read -r -d '' f; do
  if file "$f" | grep -q 'Mach-O'; then
    codesign --force --sign - "$f" >/dev/null
  fi
done < <(find "$APP" -type f -print0)
codesign --force --sign - "$APP" >/dev/null

codesign --verify --deep --strict --verbose=1 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E 'Identifier|flags' | sed 's/^/  /'

if [ -n "$DMG" ]; then
  volume=$(basename "$APP" .app)
  staging=$(mktemp -d "${TMPDIR:-/tmp}/jan-dmg.XXXXXX")
  trap 'rm -rf "$staging"' EXIT
  cp -R "$APP" "$staging/"
  ln -s /Applications "$staging/Applications"   # drag-to-install, like tauri's dmg
  hdiutil create -volname "$volume" -srcfolder "$staging" -ov -format UDZO "$DMG" >/dev/null
  hdiutil verify "$DMG" >/dev/null
  echo "rewrote dmg with the signed app: $DMG"
  ls -lh "$DMG" "$APP" | sed 's/^/  /'
else
  echo "note: no .dmg under $BUNDLE_DIR/dmg; signed the .app only"
fi
