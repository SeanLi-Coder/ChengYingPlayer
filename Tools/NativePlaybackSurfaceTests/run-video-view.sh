#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-video-view-tests.XXXXXX")"
trap 'rm -f "$test_dir/view-tests"' EXIT
xcrun swiftc -swift-version 5 -target arm64-apple-macos12 \
  -import-objc-header iina/NativePlayback/CYNMediaDecoder.h \
  iina/Atomic.swift iina/Lock.swift iina/ReadWriteAtomic.swift iina/ReadWriteLock.swift \
  iina/MPVOption.swift iina/MPVProperty.swift \
  iina/NativePlayback/NativeSampleBufferOutput.swift \
  iina/NativePlayback/NativePlaybackSurface.swift iina/VideoView.swift \
  Tools/NativePlaybackSurfaceTests/VideoViewBoundary.swift \
  Tools/NativePlaybackSurfaceTests/VideoViewMain.swift \
  -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -o "$test_dir/view-tests"
printf 'Artifacts: %s\n' "$test_dir"
/usr/bin/perl -e 'alarm 20; exec @ARGV' "$test_dir/view-tests" 2>&1 | tee "$test_dir/results.log"
