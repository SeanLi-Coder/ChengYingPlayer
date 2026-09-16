#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/chengying-image-slideshow-tests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
xcrun swiftc -o "$test_root/ImageSlideshowTests" \
  "$project_root/iina/ImageViewer/ImageSlideshowPolicy.swift" \
  "$project_root/Tools/ImageSlideshowTests/main.swift"
"$test_root/ImageSlideshowTests"
xcrun swiftc -target x86_64-apple-macosx10.15 -typecheck \
  "$project_root/iina/ImageViewer/ImageSlideshowPolicy.swift"
