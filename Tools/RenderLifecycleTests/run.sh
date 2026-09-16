#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source_root="${RENDER_LIFECYCLE_SOURCE_ROOT:-$project_root}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-render-lifecycle.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

xcrun swift "$project_root/Tools/RenderLifecycleTests/extract.swift" "$source_root" "$test_dir"
sources=(
  "$project_root/iina/Atomic.swift"
  "$project_root/iina/Lock.swift"
  "$project_root/iina/ReadWriteAtomic.swift"
  "$project_root/iina/ReadWriteLock.swift"
  "$test_dir/Layer.swift"
  "$test_dir/View.swift"
  "$project_root/Tools/RenderLifecycleTests/Boundary.swift"
  "$project_root/Tools/RenderLifecycleTests/main.swift"
)
xcrun swiftc -suppress-warnings -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
xcrun swiftc -suppress-warnings -sanitize=address -o "$test_dir/RenderLifecycleTests" "${sources[@]}"
ASAN_OPTIONS=detect_leaks=0 "$test_dir/RenderLifecycleTests" "${1:-all}"
