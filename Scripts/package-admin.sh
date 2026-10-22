#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${HOGTIED_BUILD_DIR:-${MHK_BUILD_DIR:-$PROJECT_DIR/.build}}"
APP_DIR="${1:?Pass the signed Hogtied.app path}"
OUTPUT_DIR="${2:-$PROJECT_DIR/dist}"
mkdir -p "$BUILD_DIR/module-cache" "$BUILD_DIR/cache" "$OUTPUT_DIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/module-cache"
export XDG_CACHE_HOME="$BUILD_DIR/cache"
swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" --cache-path "$BUILD_DIR/cache" --disable-sandbox --build-system native --product HogtiedHelper -c release
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" --cache-path "$BUILD_DIR/cache" --disable-sandbox --build-system native -c release --show-bin-path)"
STAGING_DIR="$(mktemp -d "$BUILD_DIR/admin-package.XXXXXX")"
PAYLOAD_DIR="$STAGING_DIR/root"
SUPPORT_DIR="$PAYLOAD_DIR/Library/Application Support/MemoryHogKiller"
mkdir -p "$PAYLOAD_DIR/Applications" "$PAYLOAD_DIR/Library/PrivilegedHelperTools" "$PAYLOAD_DIR/Library/LaunchDaemons" "$SUPPORT_DIR" "$STAGING_DIR/scripts"
ditto "$APP_DIR" "$PAYLOAD_DIR/Applications/Hogtied.app"
HELPER_PATH="$PAYLOAD_DIR/Library/PrivilegedHelperTools/local.memoryhogkiller.helper"
cp "$BIN_DIR/HogtiedHelper" "$HELPER_PATH"
codesign --force --sign - --options runtime --identifier local.memoryhogkiller.helper "$HELPER_PATH"
codesign --verify --strict "$APP_DIR"
codesign --verify --strict "$HELPER_PATH"
CLIENT_HASH="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')"
HELPER_HASH="$(codesign -dv --verbose=4 "$HELPER_PATH" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')"
if [[ ${#CLIENT_HASH} != 40 || ${#HELPER_HASH} != 40 ]]; then
    echo "Could not read code identities." >&2; exit 1
fi
TRUST_PATH="$SUPPORT_DIR/Trust.plist"
/usr/libexec/PlistBuddy -c "Add :ClientCodeHash string $CLIENT_HASH" -c "Add :HelperCodeHash string $HELPER_HASH" -c 'Add :AllowedUserID integer 0' "$TRUST_PATH"
cp "$PROJECT_DIR/Assets/AdminHelper.plist" "$PAYLOAD_DIR/Library/LaunchDaemons/local.memoryhogkiller.helper.plist"
cp "$PROJECT_DIR/Scripts/Uninstall-Admin-Helper.command" "$SUPPORT_DIR/Uninstall Admin Helper.command"
cp "$PROJECT_DIR/Scripts/AdminInstaller/postinstall" "$STAGING_DIR/scripts/postinstall"
chmod 755 "$STAGING_DIR/scripts/postinstall" "$SUPPORT_DIR/Uninstall Admin Helper.command" "$HELPER_PATH"
pkgbuild --analyze --root "$PAYLOAD_DIR" "$STAGING_DIR/components.plist"
# Always install the matching signed app into /Applications, even if a copy
# is already running from Downloads or another build has the same version.
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' -c 'Set :0:BundleIsVersionChecked false' "$STAGING_DIR/components.plist"
pkgbuild --root "$PAYLOAD_DIR" --component-plist "$STAGING_DIR/components.plist" --scripts "$STAGING_DIR/scripts" --identifier local.memoryhogkiller.admin --version 1.3.0 --install-location / --ownership recommended "$OUTPUT_DIR/Hogtied Admin Helper.pkg"
echo "Built $OUTPUT_DIR/Hogtied Admin Helper.pkg"
