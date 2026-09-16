#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/chengying-image-tests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
if [[ -x "$project_root/deps/executable/chengying-image-codec" ]]; then
  cp "$project_root/deps/executable/chengying-image-codec" "$test_root/"
fi
xcrun swiftc -o "$test_root/ImageViewerTests" \
  "$project_root/iina/ImageViewer/ImageFileSupport.swift" \
  "$project_root/iina/ImageViewer/ImageDocument.swift" \
  "$project_root/iina/ImageViewer/ImageConverter.swift" \
  "$project_root/Tools/ImageViewerTests/main.swift"
"$test_root/ImageViewerTests" "$test_root"
xcrun swiftc -target x86_64-apple-macosx10.15 -typecheck \
  "$project_root/iina/ImageViewer/ImageFileSupport.swift" \
  "$project_root/iina/ImageViewer/ImageDocument.swift" \
  "$project_root/iina/ImageViewer/ImageConverter.swift"
