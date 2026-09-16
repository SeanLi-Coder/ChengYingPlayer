#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-history-search.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

sources=(
  "$project_root/Tools/HistorySearchTests/Stubs.swift"
  "$project_root/Tools/PlaybackTimeTests/TimeSupport.swift"
  "$project_root/iina/VideoTime.swift"
  "${HISTORY_CONTROLLER_SOURCE:-$project_root/iina/HistoryWindowController.swift}"
  "$project_root/Tools/HistorySearchTests/main.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
xcrun swiftc -o "$test_dir/HistorySearchTests" "${sources[@]}"
"$test_dir/HistorySearchTests"
