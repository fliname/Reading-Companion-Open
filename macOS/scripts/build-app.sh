#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
BUILD_CACHE=/private/tmp/reading-companion-clang-cache
SWIFTPM_CACHE=/private/tmp/reading-companion-swiftpm-cache
SWIFTPM_CONFIG=/private/tmp/reading-companion-swiftpm-config
SWIFTPM_SECURITY=/private/tmp/reading-companion-swiftpm-security
APP_DIR="$PROJECT_DIR/dist/Reading Companion Open.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$PROJECT_DIR"
env CLANG_MODULE_CACHE_PATH="$BUILD_CACHE" swift build \
  --disable-sandbox \
  --configuration release \
  --scratch-path .build \
  --cache-path "$SWIFTPM_CACHE" \
  --config-path "$SWIFTPM_CONFIG" \
  --security-path "$SWIFTPM_SECURITY"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
install -m 755 .build/release/ReadingCompanion "$MACOS_DIR/ReadingCompanion"
install -m 644 Resources/Info.plist "$CONTENTS_DIR/Info.plist"
install -m 644 Resources/AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"

"$SCRIPT_DIR/bundle-enhanced-toc.sh" "$RESOURCES_DIR/EnhancedTOC"

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
