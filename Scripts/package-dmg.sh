#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${HOGTIED_BUILD_DIR:-${MHK_BUILD_DIR:-$PROJECT_DIR/.build}}"
APP_DIR="${1:?Pass the signed Hogtied.app path}"
OUTPUT_DIR="${2:-$PROJECT_DIR/dist}"
HELPER_PACKAGE="$OUTPUT_DIR/Hogtied Admin Helper.pkg"
codesign --verify --strict "$APP_DIR"
test -f "$HELPER_PACKAGE"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
ARCHITECTURE="$(lipo -archs "$APP_DIR/Contents/MacOS/Hogtied")"
case "$ARCHITECTURE" in
    arm64|x86_64) ;;
    *) ARCHITECTURE="universal" ;;
esac
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
STAGING_DIR="$(mktemp -d "$BUILD_DIR/dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_DIR" "$STAGING_DIR/Hogtied.app"
cp "$HELPER_PACKAGE" "$STAGING_DIR/Hogtied Admin Helper.pkg"
cp "$PROJECT_DIR/README.md" "$STAGING_DIR/Hogtied Read Me.md"
ln -s /Applications "$STAGING_DIR/Applications"
cat > "$STAGING_DIR/Start Here.txt" <<EOF
Hogtied $VERSION for macOS 13 or later ($ARCHITECTURE)

Ordinary installation:
1. Quit any older running copy of Hogtied or Memory Hog Killer.
2. Drag Hogtied.app to the Applications shortcut.
3. Open Hogtied from Applications, then eject this disk image.

Optional administrator helper:
Open Hogtied Admin Helper.pkg instead. It installs the matching app into
Applications and asks for administrator authentication for the helper.
Use this matching installer to update an existing administrator helper.

Your saved settings and paused entries carry forward. To quit individual
offenders, choose Settings > Quit mode > Only processes over the limit.

The app uses ad hoc signing. The app, installer, and disk image are not
Developer ID signed or notarized. See Hogtied Read Me.md for details.

Source and instructions: https://github.com/akrabu/Hogtied
EOF
DMG_PATH="$OUTPUT_DIR/Hogtied-$VERSION-$ARCHITECTURE.dmg"
hdiutil create -volname "Hogtied $VERSION" -srcfolder "$STAGING_DIR" -fs HFS+ -format UDZO -ov "$DMG_PATH"
hdiutil verify "$DMG_PATH"
echo "Built $DMG_PATH"
