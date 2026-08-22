#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")
STAGING_ROOT=$(mktemp -d /private/tmp/reading-companion-source.XXXXXX)
STAGING_PROJECT="$STAGING_ROOT/Reading-Companion-Open-$VERSION"
OUTPUT="$PROJECT_DIR/dist/Reading-Companion-Open-$VERSION-source.zip"

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
  --exclude ':memory:*' \
  --exclude 'dist' \
  --exclude 'LocalEdition' \
  --exclude 'backups' \
  --exclude 'GitHub-Upload' \
  --exclude 'Resources/AppIcon-public-source*.png' \
  --exclude 'Resources/AppIcon-alpha.png' \
  "$PROJECT_DIR/" "$STAGING_PROJECT/"

rm -f "$OUTPUT"
(
  cd "$STAGING_ROOT"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry "$OUTPUT" "Reading-Companion-Open-$VERSION"
)
echo "$OUTPUT"
