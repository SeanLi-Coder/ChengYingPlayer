#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-native-display.XXXXXX")"
trap 'rm -f "$test_dir/NativeSampleBufferDisplayTests"; rmdir "$test_dir"' EXIT
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.4 \
  -o "$test_dir/NativeSampleBufferDisplayTests" \
  "$project_root/iina/NativePlayback/NativeSampleBufferOutput.swift" \
  "$project_root/Tools/NativeSampleBufferDisplayTests/main.swift"
"$test_dir/NativeSampleBufferDisplayTests"
