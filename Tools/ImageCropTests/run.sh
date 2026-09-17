#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-image-crop.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

sources=(
  "$project_root/iina/ImageViewer/ImageFileSupport.swift"
  "$project_root/iina/ImageViewer/ImageDocument.swift"
  "$project_root/iina/ImageViewer/ImageEditing.swift"
  "$project_root/iina/ImageViewer/ImageCropGeometry.swift"
  "$project_root/iina/ImageViewer/ImageCanvasView.swift"
)
xcrun swiftc -o "$test_dir/ImageCropTests" "${sources[@]}" "$project_root/Tools/ImageCropTests/main.swift"
"$test_dir/ImageCropTests"
xcrun swiftc -target x86_64-apple-macosx10.15 -typecheck "${sources[@]}"
