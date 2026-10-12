#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-preroll-audio-tests.XXXXXX")"
ffmpeg_bin="${FFMPEG_BIN:-$repo_root/deps/executable/ffmpeg}"
ffprobe_bin="${FFPROBE_BIN:-$repo_root/deps/executable/ffprobe}"
session_source="$repo_root/iina/NativePlayback/NativePlaybackSession.swift"
output_source="$repo_root/iina/NativePlayback/NativeSampleBufferOutput.swift"
clang_sanitizer=""
swift_sanitizer=""
sanitizer_debug=""
if [[ "${NATIVE_PREROLL_SANITIZER:-}" == thread ]]; then
  clang_sanitizer="-fsanitize=thread"
  swift_sanitizer="-sanitize=thread"
  sanitizer_debug="-g"
elif [[ -n "${NATIVE_PREROLL_SANITIZER:-}" ]]; then
  printf 'Unsupported sanitizer; use thread.\n' >&2
  exit 2
fi
if [[ "${NATIVE_PREROLL_NEGATIVE:-0}" != 0 ]]; then
  python3 Tools/NativePrerollAudioTests/negative.py "$session_source" "$test_dir/NativePlaybackSession.swift" "$NATIVE_PREROLL_NEGATIVE"
  session_source="$test_dir/NativePlaybackSession.swift"
fi
if [[ "${NATIVE_PREROLL_FLUSH_DELAY:-0}" == 1 ]]; then
  python3 Tools/NativePrerollAudioTests/delay_flush.py "$output_source" "$test_dir/NativeSampleBufferOutput.swift"
  output_source="$test_dir/NativeSampleBufferOutput.swift"
fi
for name in control delayed excessive; do
  delay=0
  duration=4
  if [[ "$name" == delayed ]]; then delay=1; fi
  if [[ "$name" == excessive ]]; then delay=10; duration=13; fi
  "$ffmpeg_bin" -hide_banner -loglevel error -nostdin \
    -f lavfi -i 'color=red:s=160x90:r=30:d=3' \
    -f lavfi -i "sine=frequency=330:sample_rate=48000:duration=$duration" \
    -vf "setpts=PTS+$delay/TB" -fps_mode passthrough -c:v ffv1 -pix_fmt yuv420p \
    -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    -ac 2 -c:a pcm_f32le "$test_dir/$name.mkv"
done
for name in control delayed; do
  "$ffmpeg_bin" -hide_banner -loglevel error -nostdin -i "$test_dir/$name.mkv" \
    -fps_mode passthrough -c:v libx264 -preset fast -crf 18 -bf 8 -g 30 -x264-params b-adapt=0 -pix_fmt yuv420p \
    -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    -c:a aac "$test_dir/$name.mp4"
  b_frames="$("$ffprobe_bin" -v error -select_streams v:0 -show_frames \
    -show_entries frame=pict_type -of csv=p=0 "$test_dir/$name.mp4" \
    | awk -F, '$1 == "B" { count++ } END { print count+0 }')"
  if (( b_frames == 0 )); then
    printf 'FAIL: %s.mp4 contains no decoded B frames.\n' "$name" >&2
    exit 1
  fi
  printf 'FIXTURE: %s.mp4 has %s actual decoded B frames.\n' "$name" "$b_frames"
done
"$ffmpeg_bin" -hide_banner -loglevel error -nostdin \
  -f lavfi -i 'sine=frequency=660:sample_rate=48000:duration=1' -c:a pcm_f32le "$test_dir/audio-only.wav"
shasum -a 256 iina/NativePlayback/CYNMediaDecoder.h iina/NativePlayback/CYNMediaDecoder.m \
  "$output_source" iina/NativePlayback/NativePlaybackSampleGate.swift \
  "$session_source" Tools/NativePrerollAudioTests/main.swift Tools/NativePrerollAudioTests/run.sh \
  Tools/NativePrerollAudioTests/negative.py Tools/NativePrerollAudioTests/delay_flush.py > "$test_dir/source-sha256.txt"
git rev-parse HEAD > "$test_dir/base-commit.txt"
xcrun clang ${clang_sanitizer:+"$clang_sanitizer"} ${sanitizer_debug:+"$sanitizer_debug"} \
  -target arm64-apple-macos12 -fobjc-arc -fmodules -std=gnu11 -I deps/include -c \
  iina/NativePlayback/CYNMediaDecoder.m -o "$test_dir/decoder.o"
xcrun swiftc ${swift_sanitizer:+"$swift_sanitizer"} ${sanitizer_debug:+"$sanitizer_debug"} \
  -swift-version 5 -target arm64-apple-macos14.4 \
  -import-objc-header iina/NativePlayback/CYNMediaDecoder.h \
  "$output_source" iina/NativePlayback/NativePlaybackSampleGate.swift \
  "$session_source" Tools/NativePrerollAudioTests/main.swift "$test_dir/decoder.o" \
  deps/lib/libavcodec.61.dylib deps/lib/libavformat.61.dylib deps/lib/libavutil.59.dylib \
  deps/lib/libswresample.5.dylib deps/lib/libswscale.8.dylib \
  -Xlinker -rpath -Xlinker "$repo_root/deps/lib" -framework AppKit -framework AVFoundation \
  -framework CoreMedia -framework CoreVideo -framework AudioToolbox -o "$test_dir/preroll-tests"
shasum -a 256 -c "$test_dir/source-sha256.txt"
printf 'Artifacts: %s\n' "$test_dir"
/usr/bin/perl -e 'alarm 110; exec @ARGV' "$test_dir/preroll-tests" "$test_dir" 2>&1 | tee "$test_dir/results.log"
shasum -a 256 -c "$test_dir/source-sha256.txt"
