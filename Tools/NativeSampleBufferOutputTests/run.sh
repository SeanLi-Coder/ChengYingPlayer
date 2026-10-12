#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-native-output.XXXXXX")"
trap 'rm -f "$test_dir/NativeSampleBufferOutputTests"; rmdir "$test_dir"' EXIT
xcrun swiftc -swift-version 5 -target arm64-apple-macos12 -typecheck \
  "$project_root/iina/NativePlayback/NativeSampleBufferOutput.swift"
xcrun swiftc -swift-version 5 -target arm64-apple-macos12 -o "$test_dir/NativeSampleBufferOutputTests" \
  "$project_root/iina/NativePlayback/NativeSampleBufferOutput.swift" \
  "$project_root/Tools/NativeSampleBufferOutputTests/main.swift"
"$test_dir/NativeSampleBufferOutputTests"
