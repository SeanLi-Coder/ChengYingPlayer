#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source_root="${SCREENSHOT_PREFERENCE_SOURCE_ROOT:-$project_root}"
library_dir="${SCREENSHOT_TEST_LIBRARY_DIR:-$project_root/deps/lib}"
include_dir="${SCREENSHOT_TEST_INCLUDE_DIR:-$project_root/deps/include}"
ffmpeg="${SCREENSHOT_TEST_FFMPEG:-$project_root/deps/executable/ffmpeg}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-screenshot-preferences.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

if [[ ! -x "$ffmpeg" || ! -f "$library_dir/libmpv.2.dylib" || ! -f "$include_dir/mpv/client.h" ]]; then
  echo 'ERROR: Screenshot tests require the application FFmpeg and libmpv dependencies.' >&2
  exit 1
fi
for size in 640x360 360x640; do
  "$ffmpeg" -hide_banner -loglevel error -nostdin -f lavfi \
    -i "testsrc2=size=$size:rate=2:duration=1" -an -c:v libx264 \
    -preset ultrafast -pix_fmt yuv420p "$test_dir/$size.mp4"
done
xcrun swift "$project_root/Tools/ScreenshotPreferenceTests/extract.swift" "$source_root" "$test_dir"
sources=("$test_dir/PreferenceFixture.swift" "$project_root/Tools/ScreenshotPreferenceTests/main.swift")
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck \
  -import-objc-header "$include_dir/mpv/client.h" "${sources[@]}"
xcrun swiftc -o "$test_dir/ScreenshotPreferenceTests" \
  -import-objc-header "$include_dir/mpv/client.h" "${sources[@]}" \
  "$library_dir/libmpv.2.dylib" -Xlinker -rpath -Xlinker "$library_dir"
# Bound native decoder stalls independently of the in-process event deadlines.
/usr/bin/perl -e 'alarm 90; exec @ARGV or die "Unable to run screenshot tests: $!";' \
  "$test_dir/ScreenshotPreferenceTests" "$source_root" "$test_dir"
