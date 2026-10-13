#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-core-queue-tests.XXXXXX")"
printf 'Artifacts: %s\n' "$test_dir"
clang_flags=(); swift_flags=()
case "${NATIVE_PLAYBACK_SANITIZER:-}" in
  '') ;;
  address|thread) clang_flags+=("-fsanitize=$NATIVE_PLAYBACK_SANITIZER" -g); swift_flags+=("-sanitize=$NATIVE_PLAYBACK_SANITIZER" -g) ;;
  *) printf 'Unknown sanitizer\n'; exit 2 ;;
esac
sources=(iina/PlayerCore.swift iina/PlayerWindowController.swift iina/MainMenuActions.swift
  iina/NativePlayback/NativePlaybackResumeStore.swift iina/NativePlayback/NativePlaybackResumeService.swift
  iina/Utility.swift
  iina/MainWindowController.swift iina/PlaylistViewController.swift iina/PlaybackInfo.swift
  iina/VideoTools/VideoToolsPlayerBridge.swift iina/Atomic.swift iina/Lock.swift iina/ReadWriteAtomic.swift iina/ReadWriteLock.swift
  iina/MPVOption.swift iina/MPVProperty.swift iina/MPVCommand.swift iina/MPVNode.swift iina/PlayerState.swift iina/PlaylistPlaybackPolicy.swift
  iina/VideoTools/VideoToolsLoopPolicy.swift iina/VideoTools/VideoToolsShortcuts.swift iina/VideoTools/VideoToolsRotationIntent.swift
  iina/PlaybackBackend/PlaybackTransport.swift iina/PlaybackBackend/MPVPlaybackTransport.swift iina/PlaybackBackend/NativePlaybackTransport.swift
  iina/PlaybackBackend/NativePlaybackQueue.swift iina/PlaybackBackend/MPVQueueInstaller.swift
  iina/NativePlayback/NativeSampleBufferOutput.swift iina/NativePlayback/NativePlaybackSampleGate.swift
  iina/NativePlayback/NativePlaybackSession.swift iina/NativePlayback/NativePlaybackSurface.swift iina/VideoView.swift
  iina/NativePlayback/CYNMediaDecoder.h iina/NativePlayback/CYNMediaDecoder.m
  Tools/NativePlayerRouteTests/Boundary.swift Tools/NativePlayerRouteTests/PlayerBoundary.txt
  Tools/NativePlayerCoreTests/NoURLPlaylistBoundary.txt Tools/MPVQueueInstallerTests/LiveClient.swift
  Tools/NativeCoreQueueTests/prepare.py Tools/NativeCoreQueueTests/Boundary.swift
  Tools/NativeCoreQueueTests/Bridge.h Tools/NativeCoreQueueTests/main.swift Tools/NativeCoreQueueTests/run.sh
  Tools/NativeCoreQueueTests/verify_negative.py
  deps/lib/libmpv.2.dylib deps/lib/libavcodec.61.dylib deps/lib/libavformat.61.dylib deps/lib/libavutil.59.dylib
  deps/lib/libswresample.5.dylib deps/lib/libswscale.8.dylib)
shasum -a 256 "${sources[@]}" > "$test_dir/source-before.sha256"
finish() {
  status=$?
  trap - EXIT
  shasum -a 256 "${sources[@]}" > "$test_dir/source-after.sha256" || status=1
  diff -u "$test_dir/source-before.sha256" "$test_dir/source-after.sha256" > "$test_dir/source-comparison.log" || status=1
  if [ -f "$test_dir/generated.sha256" ]; then shasum -a 256 -c "$test_dir/generated.sha256" > "$test_dir/generated-validation.log" 2>&1 || status=1; fi
  printf '%s\n' "$status" > "$test_dir/exit-status.txt"
  exit "$status"
}
trap finish EXIT
python3 Tools/NativeCoreQueueTests/prepare.py "$test_dir"
shasum -a 256 "$test_dir/Core.swift" "$test_dir/Services.swift" "$test_dir/Transport.swift" > "$test_dir/generated.sha256"
xcrun clang ${clang_flags[@]+"${clang_flags[@]}"} -target arm64-apple-macos12 -fobjc-arc -fmodules -std=gnu11 -I deps/include \
  -c iina/NativePlayback/CYNMediaDecoder.m -o "$test_dir/decoder.o"
xcrun swiftc ${swift_flags[@]+"${swift_flags[@]}"} -swift-version 5 -target arm64-apple-macos14.4 -suppress-warnings -I deps/include \
  -import-objc-header Tools/NativeCoreQueueTests/Bridge.h \
  iina/Atomic.swift iina/Lock.swift iina/ReadWriteAtomic.swift iina/ReadWriteLock.swift \
  iina/MPVOption.swift iina/MPVProperty.swift iina/MPVCommand.swift iina/MPVNode.swift iina/PlayerState.swift iina/PlaylistPlaybackPolicy.swift \
  iina/VideoTools/VideoToolsLoopPolicy.swift iina/VideoTools/VideoToolsShortcuts.swift iina/VideoTools/VideoToolsRotationIntent.swift \
  iina/PlaybackBackend/PlaybackTransport.swift iina/PlaybackBackend/MPVPlaybackTransport.swift "$test_dir/Transport.swift" \
  iina/PlaybackBackend/NativePlaybackQueue.swift iina/PlaybackBackend/MPVQueueInstaller.swift \
  iina/NativePlayback/NativeSampleBufferOutput.swift iina/NativePlayback/NativePlaybackSampleGate.swift \
  iina/NativePlayback/NativePlaybackSession.swift iina/NativePlayback/NativePlaybackSurface.swift iina/VideoView.swift \
  "$test_dir/Core.swift" "$test_dir/Services.swift" Tools/MPVQueueInstallerTests/LiveClient.swift \
  Tools/NativeCoreQueueTests/Boundary.swift Tools/NativeCoreQueueTests/main.swift "$test_dir/decoder.o" \
  deps/lib/libmpv.2.dylib deps/lib/libavcodec.61.dylib deps/lib/libavformat.61.dylib deps/lib/libavutil.59.dylib \
  deps/lib/libswresample.5.dylib deps/lib/libswscale.8.dylib \
  -Xlinker -rpath -Xlinker "$repo_root/deps/lib" -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework AudioToolbox \
  -o "$test_dir/queue-tests" 2>&1 | tee "$test_dir/compile.log"
if [ "${NATIVE_CORE_QUEUE_BUILD_ONLY:-0}" = 1 ]; then
  printf 'build-only\n' > "$test_dir/execution-mode.txt"
  printf 'Compiled Core queue fixture only; playback and behavioral assertions were not executed.\n'
  exit 0
fi
for color in red blue; do
  "${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}" -hide_banner -loglevel error -f lavfi -i "color=c=$color:s=160x96:r=20:d=5" \
    -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=5' -c:v libx264 -crf 18 -pix_fmt yuv420p \
    -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 -af volume=0 -c:a aac -shortest "$test_dir/$color.mp4"
done
"${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}" -hide_banner -loglevel error -i "$test_dir/red.mp4" \
  -map 0:v -map 0:a -map 0:a -c copy "$test_dir/multi-audio.mp4"
shasum -a 256 "$test_dir/"*.mp4 >> "$test_dir/generated.sha256"
set +e
CHENGYING_NATIVE_PLAYBACK=1 /usr/bin/perl -e 'alarm 120; exec @ARGV' "$test_dir/queue-tests" "$test_dir" 2>&1 | tee "$test_dir/results.log"
pipeline_status=("${PIPESTATUS[@]}")
set -e
if [ "${pipeline_status[1]}" -ne 0 ]; then exit 1; fi
if [ -n "${NATIVE_QUEUE_NEGATIVE_CONTROL:-}" ]; then
  test "${pipeline_status[0]}" -eq 1
  python3 Tools/NativeCoreQueueTests/verify_negative.py "$NATIVE_QUEUE_NEGATIVE_CONTROL" "$test_dir/results.log"
  if /usr/bin/grep -E 'Sanitizer|runtime error:|ThreadSanitizer' "$test_dir/results.log"; then exit 1; fi
else
  exit "${pipeline_status[0]}"
fi
