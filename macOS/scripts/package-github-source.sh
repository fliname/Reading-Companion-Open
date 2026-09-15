#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")
WINDOWS_VERSION=$(/usr/bin/plutil -extract version raw "$PROJECT_DIR/WindowsEdition/package.json")
STAGING_ROOT=$(mktemp -d /private/tmp/reading-companion-source.XXXXXX)
MAC_ARCHIVE_NAME="Reading-Companion-Open-$VERSION-macOS-Source"
WINDOWS_ARCHIVE_NAME="Reading-Companion-Open-$WINDOWS_VERSION-Windows-Source"
MAC_STAGING_PROJECT="$STAGING_ROOT/$MAC_ARCHIVE_NAME"
WINDOWS_STAGING_PROJECT="$STAGING_ROOT/$WINDOWS_ARCHIVE_NAME"
MAC_OUTPUT="$PROJECT_DIR/dist/$MAC_ARCHIVE_NAME.zip"
WINDOWS_OUTPUT="$PROJECT_DIR/dist/$WINDOWS_ARCHIVE_NAME.zip"

cleanup() {
  rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

mkdir -p "$PROJECT_DIR/dist"
rsync -a \
  --exclude '.DS_Store' \
  --exclude '.git' \
  --exclude '.build' \
  --exclude '.build-*' \
  --exclude '.swiftpm' \
  --exclude '.pnpm-store' \
  --exclude 'node_modules' \
  --exclude 'tmp' \
  --exclude ':memory:*' \
  --exclude 'dist' \
  --exclude 'WindowsEdition' \
  --exclude 'LocalEdition' \
  --exclude 'backups' \
  --exclude 'GitHub-Upload' \
  --exclude 'Resources/AppIcon-public-source*.png' \
  --exclude 'Resources/AppIcon-alpha.png' \
  "$PROJECT_DIR/" "$MAC_STAGING_PROJECT/"

rsync -a \
  --exclude '.DS_Store' \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude 'dist' \
  --exclude 'tmp' \
  "$PROJECT_DIR/WindowsEdition/" "$WINDOWS_STAGING_PROJECT/"

rm -f "$MAC_OUTPUT" "$WINDOWS_OUTPUT"
(
  cd "$STAGING_ROOT"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry "$MAC_OUTPUT" "$MAC_ARCHIVE_NAME"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry "$WINDOWS_OUTPUT" "$WINDOWS_ARCHIVE_NAME"
)
echo "$MAC_OUTPUT"
echo "$WINDOWS_OUTPUT"
