#!/bin/bash
# Builds dist/Perch.app (and a zip for GitHub Releases) with only the
# Command Line Tools: no Xcode needed. The app is signed with the "Perch Release Signing" certificate when it's in
# the keychain (otherwise ad hoc), and is not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
# Assembled and signed outside the repo: a Desktop or Documents folder synced by iCloud
# tags new files with Finder metadata, which makes codesign refuse the bundle.
STAGE="$(mktemp -d)"
APP="$STAGE/Perch.app"
OUT="dist/Perch.app"

echo "→ Building perch $VERSION"
# A universal binary when both slices build; Apple Silicon only otherwise.
ARCHES=()
SLICES="$(mktemp -d)"
for arch in arm64 x86_64; do
  if swift build -c release --triple "$arch-apple-macosx14.0" >/dev/null 2>&1; then
    # Each triple builds into the same folder, so copy the slice out before the next one.
    cp "$(swift build -c release --triple "$arch-apple-macosx14.0" --show-bin-path)/Perch" "$SLICES/$arch"
    ARCHES+=("$SLICES/$arch")
  else
    echo "  (skipping $arch: it didn't build)"
  fi
done
[ ${#ARCHES[@]} -gt 0 ] || { echo "Build failed"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${ARCHES[@]}" -output "$APP/Contents/MacOS/Perch"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

# Icon, drawn by the app itself.
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$APP/Contents/MacOS/Perch" --icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# The shortcuts that let the focus timer turn on Do Not Disturb (see scripts/focus-shortcut.py).
cp Resources/*.shortcut "$APP/Contents/Resources/"

xattr -cr "$APP"
# Signing identity. macOS ties permissions (Calendar, Automation…) to the app's signature. Ad-hoc ("-") gives every
# build its own signature, so each update or reinstall asks for them again. A named certificate gives every build the
# same identity, so permissions carry over. Release builds use the "Perch Release Signing" certificate (see
# docs/HOW-IT-WORKS.md, "Signing"); override with PERCH_SIGN_IDENTITY, or without it the build falls back to ad-hoc.
IDENTITY="${PERCH_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk '/"Perch Release Signing"/ {print $2; exit}')"
fi
if [ -n "$IDENTITY" ]; then
  echo "→ Signing with identity $IDENTITY"
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "→ Signing ad hoc (no \"Perch Release Signing\" certificate found: permissions will be asked for again after each build)"
  codesign --force --deep --sign - "$APP"
fi
lipo -info "$APP/Contents/MacOS/Perch"

codesign --verify "$APP"
mkdir -p dist
ditto -c -k --keepParent "$APP" "dist/perch-$VERSION.zip"
rm -rf "$OUT"
ditto "$APP" "$OUT"
rm -rf "$STAGE"
echo "✓ $OUT"
echo "✓ dist/perch-$VERSION.zip"
