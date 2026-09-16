#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source_root="${PLAYBACK_TEST_SOURCE_ROOT:-$project_root}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-playback-lifecycle.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

xcrun swift "$project_root/Tools/PlaybackLifecycleTests/extract.swift" "$source_root" "$test_dir"
sources=(
  "$project_root/Tools/PlaybackLifecycleTests/Stubs.swift"
  "$project_root/iina/PlayerState.swift"
  "$test_dir/Player.swift"
  "$test_dir/Controller.swift"
  "$project_root/Tools/PlaybackLifecycleTests/main.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
xcrun swiftc -sanitize=address -o "$test_dir/PlaybackLifecycleTests" "${sources[@]}"
ASAN_OPTIONS=detect_leaks=0 "$test_dir/PlaybackLifecycleTests" "${1:-all}"
