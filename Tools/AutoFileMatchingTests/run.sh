#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-auto-file-matching.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

# Compile the real Objective-C edit-distance implementation used by FileGroup
# matching, without bringing the unrelated AppKit portions of ObjcUtils into it.
xcrun swift "$project_root/Tools/AutoFileMatchingTests/extract.swift" "$project_root" "$test_dir"
xcrun clang -c -fobjc-arc \
  "$test_dir/EditDistance.m" -o "$test_dir/EditDistance.o"
sources=(
  "$project_root/iina/Lock.swift"
  "$project_root/iina/Atomic.swift"
  "$project_root/iina/Regex.swift"
  "$project_root/iina/MPVPlaylistItem.swift"
  "$project_root/iina/PlaylistPlaybackPolicy.swift"
  "$project_root/iina/FileGroup.swift"
  "${AUTO_FILE_MATCHER_SOURCE:-$project_root/iina/AutoFileMatcher.swift}"
  "$project_root/Tools/AutoFileMatchingTests/Boundary.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck \
  -import-objc-header "$test_dir/EditDistance.h" "${sources[@]}"
xcrun swiftc -o "$test_dir/AutoFileMatchingTests" \
  -import-objc-header "$test_dir/EditDistance.h" "${sources[@]}" \
  "$project_root/Tools/AutoFileMatchingTests/main.swift" "$test_dir/EditDistance.o"
"$test_dir/AutoFileMatchingTests"
