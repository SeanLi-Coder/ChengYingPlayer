#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source_root="${RENDER_LIFECYCLE_SOURCE_ROOT:-$project_root}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-render-updates.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

xcrun swift "$project_root/Tools/RenderLifecycleTests/extract_updates.swift" "$source_root" "$test_dir"
sources=(
  "$project_root/iina/Atomic.swift"
  "$project_root/iina/Lock.swift"
  "$project_root/iina/ReadWriteAtomic.swift"
  "$project_root/iina/ReadWriteLock.swift"
  "$test_dir/RenderUpdates.swift"
  "$project_root/Tools/RenderLifecycleTests/UpdatesBoundary.swift"
  "$project_root/Tools/RenderLifecycleTests/UpdatesMain.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
xcrun swiftc -sanitize=address -o "$test_dir/RenderUpdateTests" "${sources[@]}"
ASAN_OPTIONS=detect_leaks=0 "$test_dir/RenderUpdateTests"
