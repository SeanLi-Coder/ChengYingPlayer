#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-playback-ui-performance.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

xcrun swift "$project_root/Tools/PlaybackUIPerformanceTests/extract.swift" "$project_root" "$test_dir"
sources=(
  "$project_root/iina/PowerSource.swift"
  "$project_root/Tools/PlaybackUIPerformanceTests/Fixture.swift"
  "$test_dir/Controller.swift"
  "$project_root/Tools/PlaybackUIPerformanceTests/main.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
xcrun swiftc -O -o "$test_dir/PlaybackUIPerformanceTests" "${sources[@]}"
"$test_dir/PlaybackUIPerformanceTests"
