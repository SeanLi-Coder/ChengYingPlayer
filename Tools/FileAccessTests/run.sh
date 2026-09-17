#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 -B "$project_root/Tools/FileAccessTests/IntegrationTests.py" "$project_root"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-file-access.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
test_bundle="$test_dir/FileAccessTests.app/Contents"
snapshot_dir="${FILE_ACCESS_SNAPSHOT_DIR:-$test_dir/snapshots}"
mkdir -p "$test_bundle/MacOS" "$test_bundle/Resources" "$snapshot_dir"
cp "$project_root/Tools/FileAccessTests/Info.plist" "$test_bundle/Info.plist"
plutil -lint "$test_bundle/Info.plist"
for language in en zh-Hans; do
  mkdir -p "$test_bundle/Resources/$language.lproj"
  cp "$project_root/iina/$language.lproj/FileAccess.strings" "$test_bundle/Resources/$language.lproj/"
  plutil -lint "$project_root/iina/$language.lproj/FileAccess.strings"
done

# Compile actual production code; all workspace actions are supplied by the fixture.
sources=(
  "$project_root/iina/ChengYingStyle.swift"
  "$project_root/iina/Updates/UpdateWorkAdmission.swift"
  "$project_root/iina/FileAccessGuideWindowController.swift"
  "$project_root/iina/FileAccessGuideCoordinator.swift"
  "$project_root/Tools/FileAccessTests/FileAccessMain.swift"
)
xcrun swiftc -swift-version 5 -target x86_64-apple-macos12 -typecheck "${sources[@]}"
xcrun swiftc -swift-version 5 -target arm64-apple-macos12 \
  -o "$test_bundle/MacOS/FileAccessTests" "${sources[@]}"
for language in en zh-Hans; do
  mkdir -p "$snapshot_dir/$language"
  "$test_bundle/MacOS/FileAccessTests" "$snapshot_dir/$language" "$language" \
    -AppleLanguages "($language)" 2> >(tee "$test_dir/stderr-$language.log" >&2)
  if /usr/bin/grep -Eq 'Unable to simultaneously satisfy constraints|Unsatisfiable constraints' "$test_dir/stderr-$language.log"; then
    printf '%s\n' 'FAIL: The file access guide emitted Auto Layout conflicts.' >&2
    exit 1
  fi
done
printf 'File access screenshots: %s\n' "$snapshot_dir"
