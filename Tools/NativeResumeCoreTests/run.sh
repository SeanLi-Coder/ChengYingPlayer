#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-resume-core.XXXXXX")"
source Tools/RenderTestSupport/native_dependencies.sh
prepare_native_test_dependencies
verify_native_test_runtime
printf 'Artifacts: %s\n' "$test_dir"
swift_sources=(iina/Atomic.swift iina/Lock.swift iina/ReadWriteAtomic.swift iina/ReadWriteLock.swift
  iina/MPVOption.swift iina/MPVProperty.swift iina/MPVCommand.swift iina/MPVNode.swift iina/PlayerState.swift iina/PlaylistPlaybackPolicy.swift
  iina/VideoTools/VideoToolsLoopPolicy.swift iina/VideoTools/VideoToolsShortcuts.swift iina/VideoTools/VideoToolsRotationIntent.swift
  iina/PlaybackBackend/PlaybackTransport.swift iina/PlaybackBackend/MPVPlaybackTransport.swift
  iina/PlaybackBackend/NativePlaybackQueue.swift iina/PlaybackBackend/MPVQueueInstaller.swift
  iina/NativePlayback/NativeSampleBufferOutput.swift iina/NativePlayback/NativePlaybackSampleGate.swift
  iina/NativePlayback/NativePlaybackSession.swift iina/NativePlayback/NativePlaybackSurface.swift iina/VideoView.swift)
sources=("${swift_sources[@]}" iina/PlayerCore.swift iina/PlaybackInfo.swift iina/PlayerWindowController.swift
  iina/NativePlayback/NativePlaybackResumeStore.swift iina/NativePlayback/NativePlaybackResumeService.swift iina/Utility.swift
  iina/PlaybackBackend/NativePlaybackTransport.swift iina/VideoTools/VideoToolsPlayerBridge.swift
  iina/NativePlayback/CYNMediaDecoder.h iina/NativePlayback/CYNMediaDecoder.m
  Tools/NativePlayerRouteTests/Boundary.swift Tools/NativePlayerRouteTests/PlayerBoundary.txt
  Tools/NativePlayerCoreTests/NoURLPlaylistBoundary.txt Tools/MPVQueueInstallerTests/LiveClient.swift
  Tools/NativeCoreQueueTests/prepare.py Tools/NativeCoreQueueTests/Boundary.swift Tools/NativeCoreQueueTests/Bridge.h
  Tools/NativeGenericHandoffTests/prepare.py Tools/NativeResumeCoreTests/prepare.py
  Tools/NativeResumeCoreTests/main.swift Tools/NativeResumeCoreTests/run.sh Tools/NativeResumeCoreTests/verify.py
  Tools/NativeResumeCoreTests/labels.txt
  Tools/RenderTestSupport/native_dependencies.sh Tools/RenderTestSupport/verify_native_dependencies.py
  other/verify_playback_distribution.py)
shasum -a 256 "${sources[@]}" > "$test_dir/source-before.sha256"
finish() {
  status=$?
  trap - EXIT
  shasum -a 256 "${sources[@]}" > "$test_dir/source-after.sha256" || status=1
  diff -u "$test_dir/source-before.sha256" "$test_dir/source-after.sha256" > "$test_dir/source-diff.txt" || status=1
  for manifest in generated fixture; do
    if [[ -f "$test_dir/$manifest-sha256.txt" ]]; then
      shasum -a 256 -c "$test_dir/$manifest-sha256.txt" > "$test_dir/$manifest-validation.log" || status=1
    fi
  done
  validate_native_test_dependencies || status=1
  if [[ -f "$test_dir/owned-domain.txt" ]]; then
    IFS= read -r owned_domain < "$test_dir/owned-domain.txt"
    if [[ "$owned_domain" =~ ^NativeResumeCore\.[A-Fa-f0-9-]{36}$ ]]; then
      /usr/bin/defaults delete "$owned_domain" > "$test_dir/defaults-cleanup.log" 2>&1 || true
    else
      printf 'Invalid owned preference domain; no cleanup attempted.\n' > "$test_dir/defaults-cleanup.log"
      status=1
    fi
  fi
  printf '%s\n' "$status" > "$test_dir/exit-status.txt"
  exit "$status"
}
trap finish EXIT
clang_flags=(); swift_flags=()
case "${NATIVE_PLAYBACK_SANITIZER:-}" in
  '') ;;
  address|thread) clang_flags+=("-fsanitize=$NATIVE_PLAYBACK_SANITIZER" -g); swift_flags+=("-sanitize=$NATIVE_PLAYBACK_SANITIZER" -g) ;;
  *) exit 2 ;;
esac
python3 -B Tools/NativeResumeCoreTests/prepare.py "$test_dir"
compile() {
  xcrun clang ${clang_flags[@]+"${clang_flags[@]}"} -target arm64-apple-macos12 -fobjc-arc -fmodules -std=gnu11 \
    -I "$native_test_deps/include" -c iina/NativePlayback/CYNMediaDecoder.m -o "$test_dir/decoder.o"
  xcrun swiftc ${swift_flags[@]+"${swift_flags[@]}"} -D NATIVE_RESUME_STORE_TESTING -swift-version 5 \
    -target arm64-apple-macos14.4 -suppress-warnings -I "$native_test_deps/include" \
    -import-objc-header Tools/NativeCoreQueueTests/Bridge.h "${swift_sources[@]}" "$test_dir/Transport.swift" \
    "$test_dir/Core.swift" "$test_dir/Services.swift" "$test_dir/LiveClient.swift" "$test_dir/Boundary.swift" \
    Tools/NativeResumeCoreTests/main.swift "$test_dir/decoder.o" "${native_test_libraries[@]}" "$native_test_deps/lib/libmpv.2.dylib" \
    -Xlinker -rpath -Xlinker "$native_test_deps/lib" -framework AppKit -framework AVFoundation \
    -framework CoreMedia -framework CoreVideo -framework AudioToolbox -o "$test_dir/resume-core-tests"
}
set +e
(set -e; compile) 2>&1 | tee "$test_dir/compile.log"
compile_status=("${PIPESTATUS[@]}")
set -e
printf '%s\n' "${compile_status[0]}" > "$test_dir/compile-status.txt"
test "${compile_status[0]}" -eq 0
test "${compile_status[1]}" -eq 0
shasum -a 256 "$test_dir/"*.swift "$test_dir/decoder.o" "$test_dir/resume-core-tests" > "$test_dir/generated-sha256.txt"
if [[ "${BUILD_ONLY:-0}" == 1 ]]; then exit 0; fi
for color in red blue; do
  "${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}" -hide_banner -loglevel error -f lavfi -i "color=c=$color:s=160x96:r=20:d=6" \
    -f lavfi -i 'anullsrc=r=48000:cl=stereo' -t 6 -c:v libx264 -crf 18 -pix_fmt yuv420p \
    -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a aac "$test_dir/$color.mp4"
done
shasum -a 256 "$test_dir/red.mp4" "$test_dir/blue.mp4" > "$test_dir/fixture-sha256.txt"
set +e
CHENGYING_NATIVE_PLAYBACK=1 /usr/bin/perl -e 'alarm 150; exec @ARGV' "$test_dir/resume-core-tests" "$test_dir" 2>&1 | tee "$test_dir/results.log"
run_status=("${PIPESTATUS[@]}")
set -e
printf '%s\n' "${run_status[0]}" > "$test_dir/execution-status.txt"
test "${run_status[1]}" -eq 0
python3 -B Tools/NativeResumeCoreTests/verify.py "$test_dir" "${NATIVE_RESUME_CORE_NEGATIVE:-none}"
