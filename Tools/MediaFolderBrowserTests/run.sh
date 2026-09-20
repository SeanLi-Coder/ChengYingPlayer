#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-folder-browser.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
test_bundle="$test_dir/MediaFolderBrowserTests.app/Contents"
mkdir -p "$test_bundle/MacOS" "$test_bundle/Resources"
cp "$project_root/Tools/MediaFolderBrowserTests/Info.plist" "$test_bundle/Info.plist"
for language in en zh-Hans zh-Hant; do
  mkdir -p "$test_bundle/Resources/$language.lproj"
  cp "$project_root/iina/$language.lproj/PlaylistBrowser.strings" "$test_bundle/Resources/$language.lproj/"
done

xcrun swiftc -o "$test_bundle/MacOS/MediaFolderBrowserTests" \
  "$project_root/iina/PlaylistFileMetadata.swift" \
  "$project_root/iina/PlaylistPresentation.swift" \
  "$project_root/iina/ChengYingStyle.swift" \
  "$project_root/iina/MediaFolderBrowserView.swift" \
  "$project_root/Tools/MediaFolderBrowserTests/main.swift"
for language in en zh-Hans zh-Hant; do
  "$test_bundle/MacOS/MediaFolderBrowserTests" -AppleLanguages "($language)"
done
