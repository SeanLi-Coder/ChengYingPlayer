#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-playback-live.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

if [[ ! -f "$project_root/deps/lib/libmpv.2.dylib" || ! -f "$project_root/deps/include/mpv/client.h" ]]; then
  echo 'ERROR: Live filter tests require the fetched application libmpv dependencies.' >&2
  exit 1
fi
xcrun swift "$project_root/Tools/PlaybackLifecycleTests/extract.swift" "$project_root" "$test_dir"
xcrun swiftc -sanitize=address -o "$test_dir/LiveFilterTests" \
  -import-objc-header "$project_root/deps/include/mpv/client.h" \
  "$project_root/iina/MPVNode.swift" \
  "$test_dir/LiveController.swift" \
  "$project_root/Tools/PlaybackLifecycleTests/Live/main.swift" \
  "$project_root/deps/lib/libmpv.2.dylib" \
  -Xlinker -rpath -Xlinker "$project_root/deps/lib"
ASAN_OPTIONS=detect_leaks=0 "$test_dir/LiveFilterTests"
