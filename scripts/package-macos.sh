#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
PLIST="$PROJECT_DIR/Resources/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
ARCH=$(uname -m)
APP_NAME="Reading Companion Open.app"
DMG_NAME="Reading-Companion-Open-${VERSION}-macOS-${ARCH}.dmg"
STAGING_DIR=$(mktemp -d /private/tmp/reading-companion-dmg.XXXXXX)

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$SCRIPT_DIR/build-app.sh"
ditto "$PROJECT_DIR/dist/$APP_NAME" "$STAGING_DIR/$APP_NAME"
ditto "$PROJECT_DIR/Resources/macOS-安装说明.txt" "$STAGING_DIR/安装说明.txt"
ditto "$PROJECT_DIR/README.md" "$STAGING_DIR/README.md"
ditto "$PROJECT_DIR/QUICKSTART.md" "$STAGING_DIR/快速上手.md"
ditto "$PROJECT_DIR/TROUBLESHOOTING.md" "$STAGING_DIR/故障排查.md"
ditto "$PROJECT_DIR/PRIVACY.md" "$STAGING_DIR/隐私说明.md"
ditto "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$STAGING_DIR/第三方声明.md"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "Reading Companion Open ${VERSION}" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$PROJECT_DIR/dist/$DMG_NAME"

hdiutil verify "$PROJECT_DIR/dist/$DMG_NAME"
echo "$PROJECT_DIR/dist/$DMG_NAME"
