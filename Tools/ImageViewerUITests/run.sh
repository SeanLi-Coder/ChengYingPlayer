#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-image-ui.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -o "$test_dir/ImageViewerUITests" \
  "$project_root/iina/PlaylistFileMetadata.swift" \
  "$project_root/iina/ImageViewer/ImageCanvasView.swift" \
  "$project_root/iina/ImageViewer/ImageViewerWindowController.swift" \
  "$project_root/Tools/ImageViewerUITests/AppStubs.swift" \
  "$project_root/Tools/ImageViewerUITests/Stubs.swift" \
  "$project_root/Tools/ImageViewerUITests/main.swift"
"$test_dir/ImageViewerUITests"

xcrun swiftc -o "$test_dir/RealImageViewerSmoke" \
  "$project_root/iina/PlaylistFileMetadata.swift" \
  "$project_root/iina/ImageViewer/ImageFileSupport.swift" \
  "$project_root/iina/ImageViewer/ImageDocument.swift" \
  "$project_root/iina/ImageViewer/ImageConverter.swift" \
  "$project_root/iina/ImageViewer/ImageCanvasView.swift" \
  "$project_root/iina/ImageViewer/ImageViewerWindowController.swift" \
  "$project_root/Tools/ImageViewerUITests/AppStubs.swift" \
  "$project_root/Tools/ImageViewerUITests/RealBackend.swift"
"$test_dir/RealImageViewerSmoke"

# Verify the real backend contract on the oldest supported Intel deployment target.
xcrun swiftc -typecheck -target x86_64-apple-macosx10.15 \
  "$project_root/iina/PlaylistFileMetadata.swift" \
  "$project_root/iina/ImageViewer/ImageFileSupport.swift" \
  "$project_root/iina/ImageViewer/ImageDocument.swift" \
  "$project_root/iina/ImageViewer/ImageConverter.swift" \
  "$project_root/iina/ImageViewer/ImageCanvasView.swift" \
  "$project_root/iina/ImageViewer/ImageViewerWindowController.swift" \
  "$project_root/Tools/ImageViewerUITests/AppStubs.swift"
