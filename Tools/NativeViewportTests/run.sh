#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-viewport-tests.XXXXXX")"
printf 'Artifacts: %s\n' "$test_dir"
xcrun swift Tools/NativeViewportTests/extract.swift "$repo_root" "$test_dir"
sources=(iina/PlayerState.swift iina/MPVOption.swift iina/VideoTools/VideoToolsShortcuts.swift
  "$test_dir/NativePlaybackSurface.swift" "$test_dir/Production.swift"
  Tools/NativeViewportTests/Boundary.swift Tools/NativeViewportTests/main.swift)
compiler=(xcrun swiftc -swift-version 5)
case "${NATIVE_VIEWPORT_SANITIZER:-}" in
  "") ;;
  thread|address) compiler+=("-sanitize=$NATIVE_VIEWPORT_SANITIZER") ;;
  *) printf 'Unsupported sanitizer\n' >&2; exit 2 ;;
esac
xcrun swiftc -swift-version 5 -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
"${compiler[@]}" "${sources[@]}" -framework AppKit -framework AVFoundation \
  -o "$test_dir/viewport-tests"
shasum -a 256 iina/PlayerCore.swift iina/PlayerWindowController.swift iina/VideoView.swift \
  iina/VideoTools/VideoToolsPlayerBridge.swift iina/NativePlayback/NativePlaybackSurface.swift \
  > "$test_dir/sources.sha256"
/usr/bin/perl -e 'alarm 30; exec @ARGV' "$test_dir/viewport-tests" 2>&1 | tee "$test_dir/results.log"
