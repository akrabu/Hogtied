#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${HOGTIED_BUILD_DIR:-${MHK_BUILD_DIR:-$PROJECT_DIR/.build}}"
mkdir -p "$BUILD_DIR/module-cache" "$BUILD_DIR/cache"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/module-cache"
export XDG_CACHE_HOME="$BUILD_DIR/cache"
swift run --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" --cache-path "$BUILD_DIR/cache" --disable-sandbox --build-system native HogCoreChecks
