#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-render-corevideo.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -suppress-warnings -sanitize=address \
  "$project_root/Tools/RenderLifecycleTests/Live/main.swift" -o "$test_dir/CoreVideoProbe"
ASAN_OPTIONS=detect_leaks=0 "$test_dir/CoreVideoProbe"
