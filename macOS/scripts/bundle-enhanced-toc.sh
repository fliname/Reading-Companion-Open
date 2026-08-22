#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
DESTINATION=${1:-"$PROJECT_DIR/dist/Reading Companion Open.app/Contents/Resources/EnhancedTOC"}
LEGACY_ROOT="${READING_COMPANION_DOCLING_ROOT:-${HOME}/Library/Application Support/ReadingCompanion/Tools/Docling}"
PYTHON_SOURCE="/Library/Frameworks/Python.framework/Versions/3.14"
SITE_PACKAGES="$LEGACY_ROOT/venv/lib/python3.14/site-packages"
MODEL_SOURCE="$LEGACY_ROOT/models/docling-project--docling-layout-heron"
RAPID_MODEL_SOURCE="$LEGACY_ROOT/models/RapidOcr"
RAPID_HELPER_SOURCE="$PROJECT_DIR/scripts/rapid_toc_ocr.py"

if [[ ! -x "$PYTHON_SOURCE/bin/python3.14" \
   || ! -d "$SITE_PACKAGES/docling" \
   || ! -d "$SITE_PACKAGES/onnxruntime" \
   || ! -f "$MODEL_SOURCE/model.safetensors" \
   || ! -f "$RAPID_MODEL_SOURCE/PP-OCRv6_det_small.onnx" \
   || ! -f "$RAPID_MODEL_SOURCE/ch_ppocr_mobile_v2.0_cls_mobile.onnx" \
   || ! -f "$RAPID_MODEL_SOURCE/PP-OCRv6_rec_small.onnx" \
   || ! -f "$RAPID_HELPER_SOURCE" ]]; then
  print -u2 "Bundled OCR runtime is incomplete. Docling, ONNX Runtime, layout weights and RapidOCR Chinese weights are all required."
  exit 1
fi

rm -rf "$DESTINATION"
mkdir -p \
  "$DESTINATION/Python" \
  "$DESTINATION/site-packages" \
  "$DESTINATION/models/docling-project--docling-layout-heron" \
  "$DESTINATION/models/RapidOcr"

# Copy a private Python framework runtime. Exclude global site-packages: the
# exact pinned environment is copied separately below.
rsync -a \
  --exclude '__pycache__' \
  --exclude 'site-packages' \
  --exclude 'test' \
  --exclude 'tests' \
  "$PYTHON_SOURCE/" "$DESTINATION/Python/"

rsync -a \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  --exclude '*.dSYM' \
  --exclude 'pip' \
  --exclude 'pip-*' \
  "$SITE_PACKAGES/" "$DESTINATION/site-packages/"

rsync -a \
  --exclude '.cache' \
  "$MODEL_SOURCE/" "$DESTINATION/models/docling-project--docling-layout-heron/"

rsync -a "$RAPID_MODEL_SOURCE/" "$DESTINATION/models/RapidOcr/"
install -m 644 "$RAPID_HELPER_SOURCE" "$DESTINATION/rapid_toc_ocr.py"

# python.org's framework launcher references /Library by default. Make the
# embedded copy self-contained so it works on a Mac without Python installed.
chmod u+w "$DESTINATION/Python/bin/python3.14" "$DESTINATION/Python/Python"
install_name_tool -change \
  "/Library/Frameworks/Python.framework/Versions/3.14/Python" \
  "@executable_path/../Python" \
  "$DESTINATION/Python/bin/python3.14"
install_name_tool -id "@rpath/Python" "$DESTINATION/Python/Python"
ln -sf python3.14 "$DESTINATION/Python/bin/python3"

# Remove dangling development-only links. Broken links make macOS codesign
# report the whole app as missing even though the executable is present.
find "$DESTINATION" -type l ! -exec test -e {} \; -delete

# The python.org binaries carry Developer ID signatures. Relocation changes
# their load commands, so sign the private copies again before sealing the app.
codesign --force --sign - "$DESTINATION/Python/Python"
codesign --force --sign - "$DESTINATION/Python/bin/python3.14"

find "$DESTINATION" -type f -name '*.pyc' -delete
du -sh "$DESTINATION"
