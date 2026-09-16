#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-thumbnail-lifecycle.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

xcrun swift "$project_root/Tools/ThumbnailLifecycleTests/extract.swift" "$project_root" "$test_dir"
sources=(
  "$project_root/iina/Lock.swift"
  "$project_root/iina/Atomic.swift"
  "$project_root/iina/PlayerState.swift"
  "$project_root/Tools/ThumbnailLifecycleTests/Stubs.swift"
  "$test_dir/Player.swift"
  "$project_root/Tools/ThumbnailLifecycleTests/main.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
xcrun swiftc -sanitize=address -o "$test_dir/ThumbnailLifecycleTests" "${sources[@]}"
ASAN_OPTIONS=detect_leaks=0 "$test_dir/ThumbnailLifecycleTests"
