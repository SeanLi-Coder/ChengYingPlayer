#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
case "${NATIVE_ROUTE_NEGATIVE_CONTROL:-}" in
  ''|skip-initial-resume|skip-native-title-update|start-before-admission|ignore-opening-intent|ignore-opening-getter) ;;
  *) printf 'Unknown negative control\n'; exit 2 ;;
esac
clang_flags=()
swift_flags=()
case "${NATIVE_PLAYBACK_SANITIZER:-}" in
  '') ;;
  address|thread) clang_flags+=("-fsanitize=$NATIVE_PLAYBACK_SANITIZER" -g); swift_flags+=("-sanitize=$NATIVE_PLAYBACK_SANITIZER" -g) ;;
  *) printf 'Unknown sanitizer\n'; exit 2 ;;
esac
test_dir="$(mktemp -d "$repo_root/build/native-player-route-tests.XXXXXX")"
trap 'rm -f "$test_dir/route-tests" "$test_dir/decoder.o"' EXIT
source_files=(
  iina/PlayerCore.swift iina/PlayerWindowController.swift iina/PlaybackInfo.swift
  iina/VideoTools/VideoToolsPlayerBridge.swift iina/Atomic.swift iina/Lock.swift
  iina/ReadWriteAtomic.swift iina/ReadWriteLock.swift iina/MPVOption.swift iina/MPVProperty.swift
  iina/PlayerState.swift iina/VideoTools/VideoToolsLoopPolicy.swift iina/VideoTools/VideoToolsShortcuts.swift
  iina/VideoTools/VideoToolsRotationIntent.swift
  iina/PlaybackBackend/PlaybackTransport.swift iina/PlaybackBackend/NativePlaybackTransport.swift
  iina/PlaybackBackend/NativePlaybackQueue.swift iina/PlaybackBackend/MPVQueueInstaller.swift
  iina/NativePlayback/NativeSampleBufferOutput.swift iina/NativePlayback/NativePlaybackSampleGate.swift
  iina/NativePlayback/NativePlaybackSession.swift iina/NativePlayback/NativePlaybackSurface.swift
  iina/VideoView.swift iina/NativePlayback/CYNMediaDecoder.h iina/NativePlayback/CYNMediaDecoder.m
  Tools/NativePlayerRouteTests/Boundary.swift Tools/NativePlayerRouteTests/PlayerBoundary.txt
  Tools/NativePlayerCoreTests/NoURLPlaylistBoundary.txt
  Tools/NativePlayerCoreTests/NoNativeQueueBoundary.txt
  Tools/NativePlayerRouteTests/extract.swift Tools/NativePlayerRouteTests/main.swift Tools/NativePlayerRouteTests/run.sh
  deps/lib/libavcodec.61.dylib deps/lib/libavformat.61.dylib deps/lib/libavutil.59.dylib
  deps/lib/libswresample.5.dylib deps/lib/libswscale.8.dylib
)
shasum -a 256 "${source_files[@]}" > "$test_dir/source-before.sha256"
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
xcrun swift Tools/NativePlayerRouteTests/extract.swift "$repo_root" "$test_dir/ExtractedPlayer.swift"
xcrun clang ${clang_flags[@]+"${clang_flags[@]}"} -target arm64-apple-macos12 -fobjc-arc -fmodules -std=gnu11 -I deps/include \
  -c iina/NativePlayback/CYNMediaDecoder.m -o "$test_dir/decoder.o"
xcrun swiftc ${swift_flags[@]+"${swift_flags[@]}"} -swift-version 5 -target arm64-apple-macos14.4 -suppress-warnings \
  -import-objc-header iina/NativePlayback/CYNMediaDecoder.h \
  iina/Atomic.swift iina/Lock.swift iina/ReadWriteAtomic.swift iina/ReadWriteLock.swift \
  iina/MPVOption.swift iina/MPVProperty.swift iina/PlayerState.swift \
  iina/VideoTools/VideoToolsLoopPolicy.swift iina/VideoTools/VideoToolsShortcuts.swift \
  iina/VideoTools/VideoToolsRotationIntent.swift \
  iina/PlaybackBackend/PlaybackTransport.swift iina/PlaybackBackend/NativePlaybackTransport.swift \
  iina/PlaybackBackend/NativePlaybackQueue.swift iina/PlaybackBackend/MPVQueueInstaller.swift \
  iina/NativePlayback/NativeSampleBufferOutput.swift iina/NativePlayback/NativePlaybackSampleGate.swift \
  iina/NativePlayback/NativePlaybackSession.swift iina/NativePlayback/NativePlaybackSurface.swift \
  iina/VideoView.swift "$test_dir/ExtractedPlayer.swift" \
  Tools/NativePlayerRouteTests/Boundary.swift Tools/NativePlayerRouteTests/main.swift "$test_dir/decoder.o" \
  deps/lib/libavcodec.61.dylib deps/lib/libavformat.61.dylib deps/lib/libavutil.59.dylib \
  deps/lib/libswresample.5.dylib deps/lib/libswscale.8.dylib \
  -Xlinker -rpath -Xlinker "$repo_root/deps/lib" \
  -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework AudioToolbox \
  -o "$test_dir/route-tests"
if [ "${NATIVE_ROUTE_BUILD_ONLY:-0}" = 1 ]; then
  shasum -a 256 -c "$test_dir/source-before.sha256" > "$test_dir/source-check.log"
  printf 'Compiled route fixture only; playback was not executed. Artifacts: %s\n' "$test_dir"
  exit 0
fi
for color in red blue; do
  "$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i "color=c=$color:s=160x96:r=20:d=8" \
    -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=8' \
    -c:v libx264 -crf 0 -pix_fmt yuv420p -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    -c:a aac -shortest "$test_dir/$color.mp4"
done
"$ffmpeg_bin" -hide_banner -loglevel error -i "$test_dir/red.mp4" \
  -map 0:v -map 0:a -map 0:a -c copy "$test_dir/multi-audio.mp4"
printf 'Artifacts: %s\n' "$test_dir"
shasum -a 256 "$test_dir/ExtractedPlayer.swift" "$test_dir/red.mp4" "$test_dir/blue.mp4" "$test_dir/multi-audio.mp4" > "$test_dir/generated.sha256"
set +e
CHENGYING_NATIVE_PLAYBACK=1 /usr/bin/perl -e 'alarm 180; exec @ARGV' \
  "$test_dir/route-tests" "$test_dir" 2>&1 | tee "$test_dir/results.log"
pipeline_status=("${PIPESTATUS[@]}")
test_status=${pipeline_status[0]}
tee_status=${pipeline_status[1]}
shasum -a 256 "${source_files[@]}" > "$test_dir/source-after.sha256"
source_status=$?
diff -u "$test_dir/source-before.sha256" "$test_dir/source-after.sha256" > "$test_dir/source-comparison.log"
hash_status=$?
shasum -a 256 -c "$test_dir/generated.sha256" > "$test_dir/generated-validation.log" 2>&1
generated_status=$?
if [ "$source_status" -ne 0 ] || [ "$hash_status" -ne 0 ] || [ "$generated_status" -ne 0 ] || [ "$tee_status" -ne 0 ]; then
  printf 'FAIL: verification evidence changed or could not be saved\n'
  exit 1
fi
exit "$test_status"
