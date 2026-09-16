#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-playback-time.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

sources=(
  "$project_root/Tools/PlaybackTimeTests/TimeSupport.swift"
  "${PLAYBACK_TIME_SOURCE:-$project_root/iina/VideoTime.swift}"
  "$project_root/Tools/PlaybackTimeTests/main.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
xcrun swiftc -o "$test_dir/PlaybackTimeTests" "${sources[@]}"
"$test_dir/PlaybackTimeTests"
