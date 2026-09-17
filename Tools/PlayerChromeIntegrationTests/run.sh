#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-player-chrome-integration.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
snapshot_dir="${PLAYER_CHROME_INTEGRATION_SNAPSHOT_DIR:-$test_dir/snapshots}"
mkdir -p "$snapshot_dir"
python3 "$project_root/Tools/PlayerChromeIntegrationTests/extract.py" "$project_root" "$test_dir/Extracted.swift"
xcrun swiftc -target arm64-apple-macos12 -o "$test_dir/ChromeIntegrationTests" \
  "$test_dir/Extracted.swift" \
  "$project_root/iina/PlayerEdgeControlsView.swift" \
  "$project_root/iina/TimeLabelOverflowedView.swift" \
  "$project_root/iina/ChengYingStyle.swift" \
  "$project_root/iina/MediaInfo/MediaInfoModels.swift" \
  "$project_root/iina/PlaylistFileMetadata.swift" \
  "$project_root/iina/PlaylistPresentation.swift" \
  "$project_root/Tools/PlayerChromeTests/Fixture.swift" \
  "$project_root/Tools/PlayerChromeIntegrationTests/main.swift"
"$test_dir/ChromeIntegrationTests" "$project_root/iina/Base.lproj/MainWindowController.xib" \
  "$project_root/iina/Base.lproj/PlaylistViewController.xib" "$snapshot_dir" 2>&1 | tee "$test_dir/runtime.log"
if /usr/bin/grep -nE 'Unable to simultaneously satisfy constraints|Will attempt to recover by breaking constraint' "$test_dir/runtime.log"; then
  echo "FAIL: The native layout reported conflicting constraints."
  exit 1
else
  grep_status=$?
  if [[ "$grep_status" -ne 1 ]]; then
    echo "FAIL: The constraint-conflict check could not read its log."
    exit "$grep_status"
  fi
fi
