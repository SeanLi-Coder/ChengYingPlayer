#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-playback-soak.XXXXXX")"
trap 'rm -f "$test_dir/soak-tests" "$test_dir/decoder.o" "$test_dir/memory.o"' EXIT
seconds="${NATIVE_SOAK_SECONDS:-180}"
case "$seconds" in
  ''|*[!0-9]*) echo 'ERROR: NATIVE_SOAK_SECONDS must be an integer.' >&2; exit 2 ;;
esac
if (( seconds < 60 || seconds > 1800 )); then
  echo 'ERROR: NATIVE_SOAK_SECONDS must be between 60 and 1800.' >&2
  exit 2
fi
ffmpeg="$repo_root/deps/executable/ffmpeg"
test_sources="$repo_root/Tools/NativePlaybackSoakTests"
/usr/bin/shasum -a 256 iina/NativePlayback/CYNMediaDecoder.h iina/NativePlayback/CYNMediaDecoder.m \
  iina/NativePlayback/NativeSampleBufferOutput.swift iina/NativePlayback/NativePlaybackSampleGate.swift \
  iina/NativePlayback/NativePlaybackSession.swift iina/NativePlayback/NativePlaybackSurface.swift \
  Tools/NativePlaybackSoakTests/Memory.h Tools/NativePlaybackSoakTests/Memory.c \
  Tools/NativePlaybackSoakTests/main.swift > "$test_dir/source-sha256.txt"
xcrun clang -target arm64-apple-macos12 -fobjc-arc -fmodules -std=gnu11 -I deps/include -c \
  iina/NativePlayback/CYNMediaDecoder.m -o "$test_dir/decoder.o"
xcrun clang -target arm64-apple-macos14.4 -x objective-c -fobjc-arc -Wall -Wextra -Werror -I iina/NativePlayback \
  -c "$test_sources/Memory.c" -o "$test_dir/memory.o"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.4 \
  -import-objc-header "$test_sources/Memory.h" -I iina/NativePlayback \
  iina/NativePlayback/NativeSampleBufferOutput.swift \
  iina/NativePlayback/NativePlaybackSampleGate.swift \
  iina/NativePlayback/NativePlaybackSession.swift \
  iina/NativePlayback/NativePlaybackSurface.swift \
  "$test_sources/main.swift" "$test_dir/decoder.o" "$test_dir/memory.o" \
  deps/lib/libavcodec.61.dylib deps/lib/libavformat.61.dylib deps/lib/libavutil.59.dylib \
  deps/lib/libswresample.5.dylib deps/lib/libswscale.8.dylib \
  -Xlinker -rpath -Xlinker "$repo_root/deps/lib" \
  -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework AudioToolbox -o "$test_dir/soak-tests"
/usr/bin/shasum -a 256 -c "$test_dir/source-sha256.txt"
echo 'Generating isolated 4K H.264/AAC and HEVC Main10/AAC fixtures.'
"$ffmpeg" -hide_banner -loglevel error -nostdin \
  -f lavfi -i 'color=red:s=3840x2160:r=24:d=2[a];color=lime:s=3840x2160:r=24:d=2[b];color=blue:s=3840x2160:r=24:d=2[c];color=magenta:s=3840x2160:r=24:d=2[d];[a][b][c][d]concat=n=4:v=1:a=0' \
  -f lavfi -i 'anullsrc=r=48000:cl=stereo' -t 8 \
  -c:v libx264 -preset ultrafast -crf 0 -threads 4 -g 24 -bf 3 -pix_fmt yuv420p \
  -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a aac -movflags +faststart "$test_dir/h264.mp4"
"$ffmpeg" -hide_banner -loglevel error -nostdin -i "$test_dir/h264.mp4" \
  -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le \
  -x265-params 'lossless=1:log-level=error:pools=4:frame-threads=2:keyint=24' \
  -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -tag:v hvc1 -c:a copy -movflags +faststart "$test_dir/hevc-main10.mp4"
# Read reference pixels independently with FFmpeg. The test checks retained YUV
# code values, not a claim that synthetic color labels certify physical color.
for fixture in h264.mp4 hevc-main10.mp4; do
  bits=8; pixel_format=yuv420p; units=tu1
  if [[ "$fixture" == hevc-main10.mp4 ]]; then bits=10; pixel_format=yuv420p10le; units=tu2; fi
  for point in '0|0.25' '1|2.25' '2|4.25' '3|6.25'; do
    phase="${point%%|*}"; position="${point#*|}"
    bytes="$("$ffmpeg" -hide_banner -loglevel error -nostdin -ss "$position" \
      -i "$test_dir/$fixture" -vf 'crop=2:2:8:8' -frames:v 1 -f rawvideo \
      -pix_fmt "$pixel_format" - | od -An -"$units" | xargs)"
    printf '%s\t%s\t%s\t%s\n' "$fixture" "$phase" "$bits" "$bytes" >> "$test_dir/references.tsv"
  done
done
printf 'Artifacts: %s\n' "$test_dir"
/usr/bin/perl -e '$seconds = shift @ARGV; alarm($seconds + 150); exec @ARGV' "$seconds" \
  "$test_dir/soak-tests" "$test_dir" "$seconds" 2>&1 | tee "$test_dir/results.log"
