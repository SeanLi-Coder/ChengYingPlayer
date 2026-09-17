#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-image-slideshow-ui.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -o "$test_dir/ImageSlideshowUITests" \
  "$project_root/iina/Updates/UpdateWorkAdmission.swift" \
  "$project_root/iina/MediaInfo/MediaInfoModels.swift" \
  "$project_root/iina/PlaylistFileMetadata.swift" \
  "$project_root/iina/ImageViewer/ImageSlideshowPolicy.swift" \
  "$project_root/iina/ImageViewer/ImageCanvasView.swift" \
  "$project_root/iina/ImageViewer/ImageViewerWindowController.swift" \
  "$project_root/Tools/ImageViewerUITests/AppStubs.swift" \
  "$project_root/Tools/ImageSlideshowUITests/Stubs.swift" \
  "$project_root/Tools/ImageSlideshowUITests/main.swift"
"$test_dir/ImageSlideshowUITests"
