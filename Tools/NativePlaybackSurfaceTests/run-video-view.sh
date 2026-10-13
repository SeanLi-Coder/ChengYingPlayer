#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
case "${NATIVE_VIEW_NEGATIVE_CONTROL:-}" in
  ''|skip-retirement-detach|ignore-output-owner) ;;
  *) printf 'Unknown negative control\n' >&2; exit 2 ;;
esac
swift_flags=()
case "${NATIVE_PLAYBACK_SANITIZER:-}" in
  '') ;;
  address|thread) swift_flags+=("-sanitize=$NATIVE_PLAYBACK_SANITIZER" -g) ;;
  *) printf 'Unknown sanitizer\n' >&2; exit 2 ;;
esac
test_dir="$(mktemp -d "$repo_root/build/native-video-view-tests.XXXXXX")"
trap 'rm -f "$test_dir/view-tests"' EXIT
sources=(iina/PlayerCore.swift iina/VideoView.swift iina/PlayerState.swift
  iina/Atomic.swift iina/Lock.swift iina/ReadWriteAtomic.swift iina/ReadWriteLock.swift
  iina/MPVOption.swift iina/MPVProperty.swift iina/NativePlayback/CYNMediaDecoder.h
  iina/NativePlayback/NativeSampleBufferOutput.swift iina/NativePlayback/NativePlaybackSurface.swift
  Tools/NativePlaybackSurfaceTests/VideoViewBoundary.swift Tools/NativePlaybackSurfaceTests/VideoViewMain.swift
  Tools/NativePlayerCoreTests/NoResumeTypes.swift Tools/NativePlayerCoreTests/NoResumeMethods.txt
  Tools/NativePlaybackSurfaceTests/extract-retirement.swift Tools/NativePlaybackSurfaceTests/run-video-view.sh)
shasum -a 256 "${sources[@]}" > "$test_dir/source.sha256"
xcrun swift Tools/NativePlaybackSurfaceTests/extract-retirement.swift "$repo_root" "$test_dir"
shasum -a 256 "$test_dir/Retirement.swift" "$test_dir/VideoView.swift" > "$test_dir/generated.sha256"
xcrun swiftc ${swift_flags[@]+"${swift_flags[@]}"} -swift-version 5 -target arm64-apple-macos12 \
  -import-objc-header iina/NativePlayback/CYNMediaDecoder.h \
  iina/Atomic.swift iina/Lock.swift iina/ReadWriteAtomic.swift iina/ReadWriteLock.swift \
  iina/MPVOption.swift iina/MPVProperty.swift iina/PlayerState.swift \
  iina/NativePlayback/NativeSampleBufferOutput.swift \
  iina/NativePlayback/NativePlaybackSurface.swift "$test_dir/VideoView.swift" "$test_dir/Retirement.swift" \
  Tools/NativePlaybackSurfaceTests/VideoViewBoundary.swift \
  Tools/NativePlayerCoreTests/NoResumeTypes.swift \
  Tools/NativePlaybackSurfaceTests/VideoViewMain.swift \
  -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -o "$test_dir/view-tests"
printf 'Artifacts: %s\n' "$test_dir"
if [[ "${NATIVE_VIEW_BUILD_ONLY:-0}" == 1 ]]; then
  shasum -a 256 -c "$test_dir/source.sha256" > "$test_dir/source-validation.log"
  shasum -a 256 -c "$test_dir/generated.sha256" > "$test_dir/generated-validation.log"
  printf 'Compiled VideoView fixture only; no behavioral assertions were executed.\n'
  exit 0
fi
set +e
/usr/bin/perl -e 'alarm 20; exec @ARGV' "$test_dir/view-tests" 2>&1 | tee "$test_dir/results.log"
statuses=("${PIPESTATUS[@]}")
shasum -a 256 -c "$test_dir/source.sha256" > "$test_dir/source-validation.log" 2>&1
source_status=$?
shasum -a 256 -c "$test_dir/generated.sha256" > "$test_dir/generated-validation.log" 2>&1
generated_status=$?
set -e
[[ "$source_status" == 0 && "$generated_status" == 0 ]] || exit 2
[[ "${statuses[1]}" == 0 ]] || exit "${statuses[1]}"
exit "${statuses[0]}"
