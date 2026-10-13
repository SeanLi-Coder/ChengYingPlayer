#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source_root="${PLAYBACK_TEST_SOURCE_ROOT:-$project_root}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-playback-lifecycle.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

xcrun swift "$project_root/Tools/PlaybackLifecycleTests/extract.swift" "$source_root" "$test_dir"
sources=(
  "$project_root/Tools/PlaybackLifecycleTests/Stubs.swift"
  "$project_root/Tools/NativePlayerCoreTests/NoResumeTypes.swift"
  "$project_root/iina/PlayerState.swift"
  "$project_root/iina/VideoTools/VideoToolsRotationIntent.swift"
  "$project_root/iina/PlaybackBackend/NativePlaybackQueue.swift"
  "$project_root/iina/PlaybackBackend/MPVQueueInstaller.swift"
  "$project_root/iina/MediaInfo/MediaInfoModels.swift"
  "$test_dir/Player.swift"
  "$test_dir/Controller.swift"
  "$project_root/Tools/PlaybackLifecycleTests/main.swift"
)
shasum -a 256 "${sources[@]}" "$source_root/iina/PlayerCore.swift" "$source_root/iina/MPVController.swift" \
  "$source_root/Tools/NativePlayerCoreTests/NoResumeMethods.txt" \
  "$project_root/Tools/PlaybackLifecycleTests/extract.swift" "$project_root/Tools/PlaybackLifecycleTests/run.sh" \
  > "$test_dir/inputs.sha256"
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
xcrun swiftc -sanitize=address -o "$test_dir/PlaybackLifecycleTests" "${sources[@]}"
if [[ "${PLAYBACK_LIFECYCLE_BUILD_ONLY:-0}" == 1 ]]; then
  shasum -a 256 -c "$test_dir/inputs.sha256"
  printf 'Compiled lifecycle fixture only; no behavioral assertions were executed.\n'
  exit 0
fi
ASAN_OPTIONS=detect_leaks=0 "$test_dir/PlaybackLifecycleTests" "${1:-all}"
shasum -a 256 -c "$test_dir/inputs.sha256"
