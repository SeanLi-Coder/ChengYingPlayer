#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-thumbnail-decoder.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

test_sources="$project_root/Tools/ThumbnailDecoderTests"
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck \
  -import-objc-header "$test_sources/Bridge.h" -I "$project_root/iina" "$test_sources/Importer.swift"
xcrun clang -fobjc-arc -fobjc-arc-exceptions -fsanitize=address -g \
  -I "$test_sources" -I "$project_root/iina" -I "$project_root/deps/include" \
  -framework Cocoa -framework Accelerate -framework QuartzCore \
  "$project_root/iina/FFmpegController.m" "$test_sources/main.m" \
  "$project_root/deps/lib/libavformat.61.dylib" \
  "$project_root/deps/lib/libavcodec.61.dylib" \
  "$project_root/deps/lib/libavutil.59.dylib" \
  "$project_root/deps/lib/libswscale.8.dylib" \
  -Wl,-rpath,"$project_root/deps/lib" -o "$test_dir/tests"

ffmpeg="${THUMBNAIL_TEST_FFMPEG:-$project_root/deps/executable/ffmpeg}"
"$ffmpeg" -v error -f lavfi -i 'testsrc2=size=3840x2160:rate=12' -t 1 \
  -c:v libx264 -threads 2 -preset ultrafast -g 6 -bf 2 -pix_fmt yuv420p "$test_dir/4k.mp4"
"$ffmpeg" -v error -f lavfi -i 'testsrc2=size=320x180:rate=12' -t 1 \
  -c:v libx264 -threads 1 -g 6 -bf 2 -output_ts_offset 8 "$test_dir/offset.ts"
"$ffmpeg" -v error -f lavfi -i 'sine=frequency=440:duration=0.1' "$test_dir/audio.wav"
"$ffmpeg" -v error -f lavfi -i 'testsrc2=size=640x360:rate=12' -t 0.5 \
  -c:v libx264 -threads 1 -preset ultrafast -g 3 -f mpegts "$test_dir/size1.ts"
"$ffmpeg" -v error -f lavfi -i 'testsrc2=size=320x240:rate=12' -t 0.5 \
  -c:v libx264 -threads 1 -preset ultrafast -g 3 -output_ts_offset 0.5 -f mpegts "$test_dir/size2.ts"
"$ffmpeg" -v error -i "concat:$test_dir/size1.ts|$test_dir/size2.ts" -map 0:v -c copy "$test_dir/resize.ts"
ASAN_OPTIONS=detect_leaks=0 "$test_dir/tests" "$test_dir"
