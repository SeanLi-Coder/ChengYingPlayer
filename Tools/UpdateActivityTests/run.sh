#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-update-activity.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
sources=(
  "$project_root/iina/PlayerState.swift"
  "$project_root/iina/Updates/UpdatePolicy.swift"
  "$project_root/iina/Updates/UpdateWorkAdmission.swift"
  "$project_root/iina/Updates/UpdateActivityGate.swift"
  "$project_root/Tools/UpdateActivityTests/Fixture.swift"
  "$project_root/Tools/UpdateActivityTests/Tests.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
xcrun swiftc -sanitize=address -o "$test_dir/UpdateActivityTests" "${sources[@]}"
ASAN_OPTIONS=detect_leaks=0 "$test_dir/UpdateActivityTests"

# Exercise the real process transport without opening an app or touching user data.
cp "$project_root/Tools/UpdateActivityTests/helper_fixture.py" "$test_dir/chengying-video-tools-helper"
chmod +x "$test_dir/chengying-video-tools-helper"
ln -s /usr/bin/true "$test_dir/ffmpeg"
ln -s /usr/bin/true "$test_dir/ffprobe"
xcrun swiftc -o "$test_dir/HelperDrainTests" \
  "$project_root/iina/Updates/UpdateWorkAdmission.swift" \
  "$project_root/iina/VideoTools/VideoToolsModels.swift" \
  "$project_root/iina/VideoTools/VideoToolsHelperClient.swift" \
  "$project_root/Tools/UpdateActivityTests/HelperDrainTests.swift"
"$test_dir/HelperDrainTests"
