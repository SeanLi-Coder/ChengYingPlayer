#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-image-routing-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
sources=(
  "$project_root/Tools/ImageRoutingTests/Stubs.swift"
  "$project_root/iina/ImageViewer/ImageFileSupport.swift"
  "$project_root/iina/PlaylistPlaybackPolicy.swift"
  "$project_root/iina/ImageViewer/ImageViewerCoordinator.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
xcrun swiftc -o "$test_dir/ImageRoutingTests" "${sources[@]}" "$project_root/Tools/ImageRoutingTests/main.swift"
"$test_dir/ImageRoutingTests" "$project_root"
