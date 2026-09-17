#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-media-info-window.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
snapshot_dir="${MEDIA_INFO_SNAPSHOT_DIR:-$test_dir/snapshots}"
mkdir -p "$snapshot_dir"
bundle_dir="$test_dir/MediaInfoWindowTests.app"
mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources"
cp "$project_root/Tools/MediaInfoTests/WindowInfo.plist" "$bundle_dir/Contents/Info.plist"
for language in en zh-Hans zh-Hant; do
  mkdir -p "$bundle_dir/Contents/Resources/$language.lproj"
  cp "$project_root/iina/$language.lproj/MediaInfo.strings" \
    "$bundle_dir/Contents/Resources/$language.lproj/MediaInfo.strings"
done
xcrun swiftc -target arm64-apple-macos12 -typecheck \
  "$project_root/iina/MediaInfo/MediaInfoModels.swift" \
  "$project_root/iina/ChengYingStyle.swift" \
  "$project_root/iina/MediaInfo/MediaInfoWindowController.swift"
xcrun swiftc -o "$bundle_dir/Contents/MacOS/MediaInfoWindowTests" \
  "$project_root/iina/MediaInfo/MediaInfoModels.swift" \
  "$project_root/iina/ChengYingStyle.swift" \
  "$project_root/iina/MediaInfo/MediaInfoWindowController.swift" \
  "$project_root/Tools/MediaInfoTests/WindowMain.swift"
for language in en zh-Hans zh-Hant; do
  mkdir -p "$snapshot_dir/$language"
  case "$language" in
    en) region=en_US ;;
    zh-Hans) region=zh_CN ;;
    zh-Hant) region=zh_TW ;;
  esac
  "$bundle_dir/Contents/MacOS/MediaInfoWindowTests" "$snapshot_dir/$language" "$language" \
    -AppleLanguages "($language)" -AppleLocale "$region"
done
