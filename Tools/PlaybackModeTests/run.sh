#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-playback-mode.XXXXXX")"
test_binary="$test_dir/PlaybackModeTests.app/Contents/MacOS/PlaybackModeTests"
cleanup() {
  if [[ -x "$test_binary" ]]; then "$test_binary" cleanup; fi
  rm -rf "$test_dir"
}
trap cleanup EXIT

xcrun swift "$project_root/Tools/PlaybackModeTests/extract.swift" "$project_root" "$test_dir"
sources=(
  "$project_root/iina/PlaylistPlaybackPolicy.swift"
  "$project_root/iina/PlayerState.swift"
  "$project_root/iina/MPVHook.swift"
  "$project_root/Tools/PlaybackModeTests/Boundary.swift"
  "$test_dir/Production.swift"
  "$project_root/Tools/PlaybackModeTests/main.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
xcrun swiftc -sanitize=address -o "$test_binary" "${sources[@]}"
export ASAN_OPTIONS=detect_leaks=0
"$test_binary"
for mode in file playlist off; do
  "$test_binary" "write-$mode"
  "$test_binary" "read-$mode"
done
