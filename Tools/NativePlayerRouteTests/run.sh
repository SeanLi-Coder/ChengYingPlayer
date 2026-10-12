#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-player-route-tests.XXXXXX")"
trap 'rm -f "$test_dir/route-tests" "$test_dir/decoder.o"' EXIT
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
xcrun swift Tools/NativePlayerRouteTests/extract.swift "$repo_root" "$test_dir/ExtractedPlayer.swift"
xcrun clang -target arm64-apple-macos12 -fobjc-arc -fmodules -std=gnu11 -I deps/include \
  -c iina/NativePlayback/CYNMediaDecoder.m -o "$test_dir/decoder.o"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.4 -suppress-warnings \
  -import-objc-header iina/NativePlayback/CYNMediaDecoder.h \
  iina/Atomic.swift iina/Lock.swift iina/ReadWriteAtomic.swift iina/ReadWriteLock.swift \
  iina/MPVOption.swift iina/MPVProperty.swift iina/PlayerState.swift \
  iina/VideoTools/VideoToolsLoopPolicy.swift \
  iina/PlaybackBackend/PlaybackTransport.swift iina/PlaybackBackend/NativePlaybackTransport.swift \
  iina/NativePlayback/NativeSampleBufferOutput.swift iina/NativePlayback/NativePlaybackSampleGate.swift \
  iina/NativePlayback/NativePlaybackSession.swift iina/NativePlayback/NativePlaybackSurface.swift \
  iina/VideoView.swift "$test_dir/ExtractedPlayer.swift" \
  Tools/NativePlayerRouteTests/Boundary.swift Tools/NativePlayerRouteTests/main.swift "$test_dir/decoder.o" \
  deps/lib/libavcodec.61.dylib deps/lib/libavformat.61.dylib deps/lib/libavutil.59.dylib \
  deps/lib/libswresample.5.dylib deps/lib/libswscale.8.dylib \
  -Xlinker -rpath -Xlinker "$repo_root/deps/lib" \
  -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework AudioToolbox \
  -o "$test_dir/route-tests"
for color in red blue; do
  "$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i "color=c=$color:s=160x96:r=20:d=8" \
    -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=8' \
    -c:v libx264 -crf 0 -pix_fmt yuv420p -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    -c:a aac -shortest "$test_dir/$color.mp4"
done
printf 'Artifacts: %s\n' "$test_dir"
CHENGYING_NATIVE_PLAYBACK=1 /usr/bin/perl -e 'alarm 60; exec @ARGV' \
  "$test_dir/route-tests" "$test_dir" 2>&1 | tee "$test_dir/results.log"
