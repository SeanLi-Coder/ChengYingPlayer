#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/playback-transport-tests.XXXXXX")"
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
sanitizer_mode="${NATIVE_PLAYBACK_SANITIZER:-}"
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
  *) printf 'Unsupported NATIVE_PLAYBACK_SANITIZER.\n' >&2; exit 2 ;;
esac
xcrun clang ${clang_sanitizer:+"$clang_sanitizer"} ${sanitizer_debug:+"$sanitizer_debug"} -target arm64-apple-macos12 \
  -fobjc-arc -fmodules -std=gnu11 -I deps/include -c \
  iina/NativePlayback/CYNMediaDecoder.m -o "$test_dir/decoder.o"
xcrun swiftc ${swift_sanitizer:+"$swift_sanitizer"} ${sanitizer_debug:+"$sanitizer_debug"} -swift-version 5 -target arm64-apple-macos12 \
  -import-objc-header iina/NativePlayback/CYNMediaDecoder.h \
  iina/NativePlayback/NativeSampleBufferOutput.swift \
  iina/NativePlayback/NativePlaybackSampleGate.swift \
  iina/NativePlayback/NativePlaybackSession.swift \
  iina/PlaybackBackend/PlaybackTransport.swift \
  iina/PlaybackBackend/MPVPlaybackTransport.swift \
  iina/PlaybackBackend/NativePlaybackTransport.swift \
  Tools/PlaybackTransportTests/main.swift "$test_dir/decoder.o" \
  deps/lib/libavcodec.61.dylib deps/lib/libavformat.61.dylib deps/lib/libavutil.59.dylib \
  deps/lib/libswresample.5.dylib deps/lib/libswscale.8.dylib \
  -Xlinker -rpath -Xlinker "$repo_root/deps/lib" \
  -framework AppKit -framework AVFoundation -framework CoreMedia \
  -framework CoreVideo -framework AudioToolbox -o "$test_dir/transport-tests"
"$ffmpeg_bin" -nostdin -hide_banner -loglevel error \
  -f lavfi -i testsrc2=s=320x180:r=30:d=3 \
  -f lavfi -i anullsrc=r=48000:cl=stereo -t 3 \
  -c:v ffv1 -pix_fmt yuv420p -color_range tv \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a pcm_f32le "$test_dir/transport.mkv"
printf 'Artifacts: %s\n' "$test_dir"
/usr/bin/perl -e 'alarm 60; exec @ARGV' "$test_dir/transport-tests" "$test_dir/transport.mkv" 2>&1 | tee "$test_dir/results.log"
