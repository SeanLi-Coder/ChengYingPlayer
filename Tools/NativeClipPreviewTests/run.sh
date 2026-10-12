#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-clip-preview-tests.XXXXXX")"
source_files=(
  iina/PlayerCore.swift iina/PlayerWindowController.swift iina/MainWindowController.swift iina/QuickSettingViewController.swift
  iina/PlayerState.swift
  iina/VideoTools/VideoToolsRotationIntent.swift
  iina/VideoTools/VideoToolsPlayerBridge.swift iina/VideoTools/VideoToolsViewController.swift iina/VideoTools/VideoToolsLoopPolicy.swift
  iina/PlaybackBackend/PlaybackTransport.swift iina/PlaybackBackend/NativePlaybackTransport.swift
  iina/NativePlayback/NativeSampleBufferOutput.swift iina/NativePlayback/NativePlaybackSampleGate.swift
  iina/NativePlayback/NativePlaybackSession.swift iina/NativePlayback/CYNMediaDecoder.h iina/NativePlayback/CYNMediaDecoder.m
  Tools/NativeClipPreviewTests/extract.swift Tools/NativeClipPreviewTests/main.swift Tools/NativeClipPreviewTests/run.sh
)
shasum -a 256 "${source_files[@]}" > "$test_dir/source-before.sha256"
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
clang_flags=()
swift_flags=()
case "${NATIVE_PREVIEW_NEGATIVE_CONTROL:-}" in
  ''|stale-input|uncancelled-position|lost-eof|stale-compatibility) ;;
  *) printf 'Unknown negative control\n'; exit 2 ;;
esac
case "${NATIVE_PLAYBACK_SANITIZER:-}" in
  '') ;;
  thread|address) clang_flags+=("-fsanitize=$NATIVE_PLAYBACK_SANITIZER" -g); swift_flags+=("-sanitize=$NATIVE_PLAYBACK_SANITIZER" -g) ;;
  *) exit 2 ;;
esac
xcrun swift Tools/NativeClipPreviewTests/extract.swift "$repo_root" "$test_dir/Production.swift"
xcrun clang ${clang_flags[@]+"${clang_flags[@]}"} -target arm64-apple-macos12 -fobjc-arc -fmodules -std=gnu11 -I deps/include \
  -c iina/NativePlayback/CYNMediaDecoder.m -o "$test_dir/decoder.o"
xcrun swiftc ${swift_flags[@]+"${swift_flags[@]}"} -swift-version 5 -target arm64-apple-macos12 \
  -import-objc-header iina/NativePlayback/CYNMediaDecoder.h \
  iina/PlaybackBackend/PlaybackTransport.swift iina/PlaybackBackend/NativePlaybackTransport.swift \
  iina/NativePlayback/NativeSampleBufferOutput.swift iina/NativePlayback/NativePlaybackSampleGate.swift \
  iina/NativePlayback/NativePlaybackSession.swift iina/VideoTools/VideoToolsLoopPolicy.swift iina/PlayerState.swift \
  iina/VideoTools/VideoToolsRotationIntent.swift \
  "$test_dir/Production.swift" "$test_dir/Panel.swift" Tools/NativeClipPreviewTests/main.swift \
  "$test_dir/decoder.o" deps/lib/libavcodec.61.dylib deps/lib/libavformat.61.dylib deps/lib/libavutil.59.dylib \
  deps/lib/libswresample.5.dylib deps/lib/libswscale.8.dylib \
  -Xlinker -rpath -Xlinker "$repo_root/deps/lib" \
  -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework AudioToolbox \
  -o "$test_dir/preview-tests"
"$ffmpeg_bin" -hide_banner -loglevel error -nostdin -f lavfi -i testsrc2=s=160x96:r=30:d=4 \
  -f lavfi -i anullsrc=r=48000:cl=stereo -t 4 -c:v ffv1 -pix_fmt yuv420p \
  -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a pcm_f32le "$test_dir/synthetic.mkv"
printf 'Artifacts: %s\n' "$test_dir"
shasum -a 256 "$test_dir/Production.swift" "$test_dir/Panel.swift" "$test_dir/synthetic.mkv" > "$test_dir/generated.sha256"
set +e
/usr/bin/perl -e 'alarm 90; exec @ARGV' "$test_dir/preview-tests" "$test_dir/synthetic.mkv" 2>&1 | tee "$test_dir/results.log"
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
  printf 'FAIL: source inputs changed during verification\n'
  exit 1
fi
exit "$test_status"
