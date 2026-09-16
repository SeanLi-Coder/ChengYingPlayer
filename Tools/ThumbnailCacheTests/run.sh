#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-thumbnail-cache.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
sources=(
  "$project_root/Tools/ThumbnailCacheTests/Stubs.swift"
  "$project_root/iina/ThumbnailCache.swift"
  "$project_root/iina/CacheManager.swift"
  "$project_root/Tools/ThumbnailCacheTests/main.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
xcrun swiftc -sanitize=address -g "${sources[@]}" -o "$test_dir/tests"
mkdir "$test_dir/cache"
ASAN_OPTIONS=detect_leaks=0 "$test_dir/tests" "$test_dir/cache" "$project_root"
