#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-player-chrome.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
snapshot_dir="${PLAYER_CHROME_SNAPSHOT_DIR:-$test_dir/snapshots}"
mkdir -p "$snapshot_dir"
xcrun swiftc -target arm64-apple-macos12 -typecheck \
  "$project_root/iina/PlayerEdgeControlsView.swift"
xcrun swiftc -o "$test_dir/PlayerChromeTests" \
  "$project_root/iina/PlayerEdgeControlsView.swift" \
  "$project_root/iina/TimeLabelOverflowedView.swift" \
  "$project_root/Tools/PlayerChromeTests/Fixture.swift" \
  "$project_root/Tools/PlayerChromeTests/main.swift"
"$test_dir/PlayerChromeTests" "$project_root/iina/Base.lproj/MainWindowController.xib" "$snapshot_dir"
