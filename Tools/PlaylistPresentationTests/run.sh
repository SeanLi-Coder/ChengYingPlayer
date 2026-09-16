#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-playlist-presentation.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
test_bundle="$test_dir/PlaylistPresentationTests.app/Contents"
mkdir -p "$test_bundle/MacOS" "$test_bundle/Resources"
cp "$project_root/Tools/PlaylistPresentationTests/Info.plist" "$test_bundle/Info.plist"
for language in en zh-Hans; do
  mkdir -p "$test_bundle/Resources/$language.lproj"
  cp "$project_root/iina/$language.lproj/PlaylistBrowser.strings" "$test_bundle/Resources/$language.lproj/"
done

xcrun swiftc -target x86_64-apple-macos10.15 -typecheck \
  "$project_root/iina/ChengYingStyle.swift" \
  "$project_root/iina/PlaylistFileMetadata.swift" \
  "$project_root/iina/PlaylistPresentation.swift"
xcrun swiftc -o "$test_bundle/MacOS/PlaylistPresentationTests" \
  "$project_root/iina/ChengYingStyle.swift" \
  "$project_root/iina/PlaylistFileMetadata.swift" \
  "$project_root/iina/PlaylistPresentation.swift" \
  "$project_root/Tools/PlaylistPresentationTests/main.swift"
for language in en zh-Hans; do
  "$test_bundle/MacOS/PlaylistPresentationTests" -AppleLanguages "($language)"
done

xcrun swift "$project_root/Tools/PlaylistPresentationTests/extract.swift" "$project_root" "$test_dir"
integration_sources=(
  "$project_root/iina/ChengYingStyle.swift"
  "$project_root/iina/PlaylistFileMetadata.swift"
  "$project_root/iina/PlaylistPresentation.swift"
  "$project_root/iina/Regex.swift"
  "$project_root/iina/MPVPlaylistItem.swift"
  "$project_root/iina/PlaylistPlaybackProgressView.swift"
  "$test_dir/Controller.swift"
  "$test_dir/Cells.swift"
  "$project_root/Tools/PlaylistPresentationTests/Integration/Boundary.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${integration_sources[@]}"
xcrun swiftc -o "$test_bundle/MacOS/PlaylistControllerTests" "${integration_sources[@]}" \
  "$project_root/Tools/PlaylistPresentationTests/Integration/XIBLayout.swift" \
  "$project_root/Tools/PlaylistPresentationTests/Integration/main.swift"
for language in en zh-Hans; do
  "$test_bundle/MacOS/PlaylistControllerTests" "$project_root" -AppleLanguages "($language)"
done
