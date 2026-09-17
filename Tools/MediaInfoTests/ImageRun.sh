#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/chengying-image-info.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

xcrun swiftc -o "$test_root/ImageMediaInfoTests" \
  "$project_root/iina/MediaInfo/MediaInfoModels.swift" \
  "$project_root/iina/MediaInfo/ImageMediaInfoReader.swift" \
  "$project_root/Tools/MediaInfoTests/ImageTests.swift"
"$test_root/ImageMediaInfoTests" "$test_root"
xcrun swiftc -target x86_64-apple-macosx10.15 -typecheck \
  "$project_root/iina/MediaInfo/MediaInfoModels.swift" \
  "$project_root/iina/MediaInfo/ImageMediaInfoReader.swift"

if /usr/bin/grep -nE 'CGImageSourceCreate(Image|Thumbnail)AtIndex\(|NSImage\(|renderPDF\(|readSVG\(url\)' \
    "$project_root/iina/MediaInfo/ImageMediaInfoReader.swift"; then
  echo "FAIL: Metadata reader must not decode or rasterize source images."
  exit 1
else
  scan_status=$?
  if [[ "$scan_status" -ne 1 ]]; then
    echo "FAIL: Unable to verify metadata-only image reading." >&2
    exit "$scan_status"
  fi
fi
echo "PASS: Image metadata reader contains no rasterization entry points."
