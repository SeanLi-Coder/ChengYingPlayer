#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-playlist-filter.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swift "$project_root/Tools/PlaylistFilterTests/extract.swift" "$project_root" "$test_dir/Controller.swift"
sources=(
  "$project_root/iina/Lock.swift"
  "$project_root/iina/Atomic.swift"
  "$project_root/iina/Regex.swift"
  "$project_root/iina/MPVPlaylistItem.swift"
  "$project_root/iina/PlaylistFileMetadata.swift"
  "$test_dir/Controller.swift"
  "$project_root/Tools/PlaylistFilterTests/Boundary.swift"
)
xcrun swiftc -swift-version 5 -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
xcrun swiftc -swift-version 5 -o "$test_dir/PlaylistFilterTests" "${sources[@]}" \
  "$project_root/Tools/PlaylistFilterTests/main.swift"
"$test_dir/PlaylistFilterTests"
