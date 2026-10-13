#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$project_root/build"
test_dir="$(mktemp -d "$project_root/build/file-tag-ui.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
mkdir "$test_dir/media"
xcrun swiftc -target arm64-apple-macos12 -o "$test_dir/PlaybackFileTagUITests" \
  "$project_root/iina/PlaybackFileTags.swift" \
  "$project_root/iina/PlaybackFileTagController.swift" \
  "$project_root/iina/PlaylistFileMetadata.swift" \
  "$project_root/iina/PlaylistPresentation.swift" \
  "$project_root/iina/ChengYingStyle.swift" \
  "$project_root/iina/Updates/UpdateWorkAdmission.swift" \
  "$project_root/Tools/PlaybackFileTagUITests/main.swift"
"$test_dir/PlaybackFileTagUITests" "$test_dir/media"
