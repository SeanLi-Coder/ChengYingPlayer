#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-welcome-design.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
test_bundle="$test_dir/WelcomeDesignTests.app/Contents"
mkdir -p "$test_bundle/MacOS" "$test_bundle/Resources"
cp "$project_root/Tools/WelcomeDesignTests/Info.plist" "$test_bundle/Info.plist"
for language in en zh-Hans; do
  mkdir -p "$test_bundle/Resources/$language.lproj"
  cp "$project_root/iina/$language.lproj/InitialWindowController.strings" "$test_bundle/Resources/$language.lproj/"
done
cp "$project_root/iina/Assets.xcassets/Icons/iina_arrow.imageset/iina-arrow.png" \
  "$test_bundle/Resources/welcome-icon.png"

# Compile the production welcome controller and shared AppKit styling.
xcrun swiftc -o "$test_bundle/MacOS/WelcomeDesignTests" \
  "$project_root/Tools/WelcomeDesignTests/Stubs.swift" \
  "$project_root/iina/ChengYingStyle.swift" \
  "$project_root/iina/ImageViewer/ImageFileSupport.swift" \
  "$project_root/iina/InitialWindowController.swift" \
  "$project_root/Tools/WelcomeDesignTests/main.swift"
for language in en zh-Hans; do
  "$test_bundle/MacOS/WelcomeDesignTests" -AppleLanguages "($language)"
done
