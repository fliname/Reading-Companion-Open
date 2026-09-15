#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_root="$project_root/vendor/libmobi-0.12"
output_root="$project_root/resources/BookConverter"
build_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/reading-companion-libmobi-0.12"

if [[ ! -f "$source_root/COPYING" ]]; then
  echo "Missing vendored libmobi 0.12 source." >&2
  exit 1
fi

rm -rf "$build_root"
mkdir -p "$build_root" "$output_root"
cp -R "$source_root/." "$build_root/"

cd "$build_root"
./autogen.sh
./configure \
  --host=x86_64-w64-mingw32 \
  --with-libxml2=no \
  --with-zlib=no \
  --enable-xmlwriter \
  --enable-encryption \
  --enable-tools-static \
  --disable-shared
make -j"$(nproc)" tools/mobitool.exe

cp tools/mobitool.exe "$output_root/mobitool.exe"
cp COPYING "$output_root/COPYING.LGPL-3.0"

test -s "$output_root/mobitool.exe"
test -s "$output_root/COPYING.LGPL-3.0"

sample="$source_root/tests/samples/sample-ncx.mobi"
if [[ -f "$sample" ]]; then
  smoke_dir="$build_root/smoke"
  mkdir -p "$smoke_dir"
  "$output_root/mobitool.exe" -e -o "$smoke_dir" "$sample"
  find "$smoke_dir" -maxdepth 1 -type f -name '*.epub' -print -quit | grep -q .
fi

echo "Bundled libmobi 0.12 mobitool: $output_root/mobitool.exe"
