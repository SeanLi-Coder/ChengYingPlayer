#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-playback-session-tests.XXXXXX")"
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
sanitizer_mode="${NATIVE_PLAYBACK_SANITIZER:-}"
diagnostic_negative="${NATIVE_PLAYBACK_DIAGNOSTIC_NEGATIVE:-0}"
case "$diagnostic_negative" in
  0|1) ;;
  *) printf 'Unsupported NATIVE_PLAYBACK_DIAGNOSTIC_NEGATIVE: use 0 or 1.\n' >&2; exit 2 ;;
esac
main_source="Tools/NativePlaybackSessionTests/main.swift"
if [[ "$diagnostic_negative" == 1 ]]; then
  # This changes only the copied test verdict, never playback or its deadline.
  python3 - "$main_source" "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
old = "  let wrapsMeetDeadline = wraps >= 2"
assert source.count(old) == 1, "Diagnostic negative-control landmark changed"
Path(sys.argv[2]).write_text(source.replace(old, "  let wrapsMeetDeadline = false", 1))
PY
  main_source="$test_dir/main.swift"
fi
shasum -a 256 iina/NativePlayback/CYNMediaDecoder.h iina/NativePlayback/CYNMediaDecoder.m \
  iina/NativePlayback/NativeSampleBufferOutput.swift iina/NativePlayback/NativePlaybackSampleGate.swift \
  iina/NativePlayback/NativePlaybackSession.swift Tools/NativePlaybackSessionTests/main.swift \
  Tools/NativePlaybackSessionTests/run.sh "$main_source" > "$test_dir/source-sha256.txt"
printf 'sanitizer=%s\ndiagnostic_negative_control=%s\n' "$sanitizer_mode" "$diagnostic_negative" > "$test_dir/mode.txt"
clang_sanitizer=""
swift_sanitizer=""
sanitizer_debug=""
case "$sanitizer_mode" in
  "") ;;
  thread|address)
    clang_sanitizer="-fsanitize=$sanitizer_mode"
    swift_sanitizer="-sanitize=$sanitizer_mode"
    sanitizer_debug="-g"
    ;;
  *)
    printf 'Unsupported NATIVE_PLAYBACK_SANITIZER: use thread or address.\n' >&2
    exit 2
    ;;
esac
xcrun clang ${clang_sanitizer:+"$clang_sanitizer"} ${sanitizer_debug:+"$sanitizer_debug"} \
  -target arm64-apple-macos12 -fobjc-arc -fmodules -std=gnu11 -I deps/include -c \
  iina/NativePlayback/CYNMediaDecoder.m -o "$test_dir/decoder.o"
xcrun swiftc ${swift_sanitizer:+"$swift_sanitizer"} ${sanitizer_debug:+"$sanitizer_debug"} \
  -swift-version 5 -target arm64-apple-macos12 \
  -import-objc-header iina/NativePlayback/CYNMediaDecoder.h \
  iina/NativePlayback/NativeSampleBufferOutput.swift \
  iina/NativePlayback/NativePlaybackSampleGate.swift \
  iina/NativePlayback/NativePlaybackSession.swift \
  "$main_source" "$test_dir/decoder.o" \
  deps/lib/libavcodec.61.dylib deps/lib/libavformat.61.dylib deps/lib/libavutil.59.dylib \
  deps/lib/libswresample.5.dylib deps/lib/libswscale.8.dylib \
  -Xlinker -rpath -Xlinker "$repo_root/deps/lib" \
  -framework AppKit -framework AVFoundation -framework CoreMedia \
  -framework CoreVideo -framework AudioToolbox -o "$test_dir/session-tests"
"$ffmpeg_bin" -hide_banner -loglevel error \
  -f lavfi -i testsrc2=s=320x180:r=30:d=3 \
  -f lavfi -i anullsrc=r=48000:cl=stereo -t 3 \
  -c:v ffv1 -pix_fmt yuv420p -color_range tv \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a pcm_f32le "$test_dir/pcm.mkv"
"$ffmpeg_bin" -hide_banner -loglevel error \
  -f lavfi -i testsrc2=s=320x180:r=30:d=3 \
  -f lavfi -i anullsrc=r=48000:cl=stereo -t 3 \
  -c:v libx264 -preset fast -bf 3 -g 30 -pix_fmt yuv420p -color_range tv \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a aac "$test_dir/aac.mp4"
"$ffmpeg_bin" -hide_banner -loglevel error \
  -f lavfi -i testsrc2=s=320x180:r=30:d=3 \
  -f lavfi -i anullsrc=r=48000:cl=stereo:d=1 \
  -c:v ffv1 -pix_fmt yuv420p -color_range tv \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a pcm_f32le "$test_dir/short-audio.mkv"
"$ffmpeg_bin" -hide_banner -loglevel error \
  -f lavfi -i testsrc2=s=320x180:r=30:d=30 \
  -f lavfi -i anullsrc=r=48000:cl=stereo:d=1 \
  -c:v ffv1 -pix_fmt yuv420p -color_range tv \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a pcm_f32le "$test_dir/long-short-audio.mkv"
"$ffmpeg_bin" -hide_banner -loglevel error \
  -f lavfi -i testsrc2=s=320x180:r=30:d=3 \
  -itsoffset 1.25 -f lavfi -i anullsrc=r=48000:cl=stereo:d=1.75 \
  -c:v ffv1 -pix_fmt yuv420p -color_range tv \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a pcm_f32le "$test_dir/delayed-audio.mkv"
"$ffmpeg_bin" -hide_banner -loglevel error \
  -f lavfi -i testsrc2=s=320x180:r=30:d=3 \
  -c:v ffv1 -pix_fmt yuv420p -color_range tv \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 "$test_dir/video-only.mkv"
"$ffmpeg_bin" -hide_banner -loglevel error \
  -f lavfi -i anullsrc=r=48000:cl=stereo:d=2 -c:a pcm_f32le "$test_dir/audio-only.wav"
printf 'Artifacts: %s\n' "$test_dir"
shasum -a 256 "$test_dir/pcm.mkv" "$test_dir/aac.mp4" "$test_dir/short-audio.mkv" \
  "$test_dir/long-short-audio.mkv" "$test_dir/delayed-audio.mkv" \
  "$test_dir/video-only.mkv" "$test_dir/audio-only.wav" > "$test_dir/fixture-sha256.txt"
set +e
/usr/bin/perl -e 'alarm 120; exec @ARGV' "$test_dir/session-tests" "$test_dir" 2>&1 | tee "$test_dir/results.log"
pipeline_status=("${PIPESTATUS[@]}")
result=${pipeline_status[0]}
if [[ "$result" == 0 && "${pipeline_status[1]}" != 0 ]]; then result=${pipeline_status[1]}; fi
set -e
shasum -a 256 -c "$test_dir/source-sha256.txt" > "$test_dir/source-validation.log"
shasum -a 256 -c "$test_dir/fixture-sha256.txt" > "$test_dir/fixture-validation.log"
exit "$result"
