#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-ab-loop-tests.XXXXXX")"
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
clang_flags=()
swift_flags=()
case "${NATIVE_PLAYBACK_SANITIZER:-}" in
  '') ;;
  thread|address) clang_flags+=("-fsanitize=$NATIVE_PLAYBACK_SANITIZER" -g); swift_flags+=("-sanitize=$NATIVE_PLAYBACK_SANITIZER" -g) ;;
  *) exit 2 ;;
esac
xcrun swift Tools/NativeABLoopTests/extract.swift "$repo_root" "$test_dir/Production.swift"
xcrun clang ${clang_flags[@]+"${clang_flags[@]}"} -target arm64-apple-macos12 -fobjc-arc -fmodules -std=gnu11 -I deps/include \
  -c iina/NativePlayback/CYNMediaDecoder.m -o "$test_dir/decoder.o"
xcrun swiftc ${swift_flags[@]+"${swift_flags[@]}"} -swift-version 5 -target arm64-apple-macos12 \
  -import-objc-header iina/NativePlayback/CYNMediaDecoder.h \
  iina/MPVOption.swift iina/MPVProperty.swift \
  iina/PlaybackBackend/PlaybackTransport.swift "$test_dir/NativePlaybackTransport.swift" \
  iina/PlaybackBackend/NativePlaybackQueue.swift iina/PlaybackBackend/MPVQueueInstaller.swift \
  iina/NativePlayback/NativeSampleBufferOutput.swift iina/NativePlayback/NativePlaybackSampleGate.swift \
  iina/NativePlayback/NativePlaybackSession.swift \
  iina/VideoTools/VideoToolsPlayerBridge.swift iina/VideoTools/VideoToolsLoopPolicy.swift \
  iina/VideoTools/VideoToolsShortcuts.swift \
  iina/VideoTools/VideoToolsRotationIntent.swift \
  "$test_dir/Production.swift" Tools/NativeABLoopTests/Boundary.swift Tools/NativeABLoopTests/main.swift \
  "$test_dir/decoder.o" deps/lib/libavcodec.61.dylib deps/lib/libavformat.61.dylib deps/lib/libavutil.59.dylib \
  deps/lib/libswresample.5.dylib deps/lib/libswscale.8.dylib \
  -Xlinker -rpath -Xlinker "$repo_root/deps/lib" \
  -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework AudioToolbox \
  -o "$test_dir/ab-tests"
"$ffmpeg_bin" -hide_banner -loglevel error -nostdin -f lavfi -i testsrc2=s=160x96:r=30:d=4 \
  -f lavfi -i anullsrc=r=48000:cl=stereo -t 4 -c:v ffv1 -pix_fmt yuv420p \
  -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a pcm_f32le "$test_dir/synthetic.mkv"
printf 'Artifacts: %s\n' "$test_dir"
/usr/bin/perl -e 'alarm 60; exec @ARGV' "$test_dir/ab-tests" "$test_dir/synthetic.mkv" 2>&1 | tee "$test_dir/results.log"
