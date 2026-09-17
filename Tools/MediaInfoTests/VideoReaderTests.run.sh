#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/chengying-video-info-tests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

xcrun clang -Wall -Wextra -Werror "$project_root/Tools/MediaInfoTests/VideoProbeFixture.c" -o "$test_root/probe-fixture"
xcrun swiftc -o "$test_root/VideoReaderTests" \
  "$project_root/iina/MediaInfo/MediaInfoModels.swift" \
  "$project_root/iina/MediaInfo/VideoMediaInfoReader.swift" \
  "$project_root/Tools/MediaInfoTests/VideoReaderTests.swift"
"$test_root/VideoReaderTests" "$test_root" "$project_root/deps/executable"
xcrun swiftc -target arm64-apple-macosx12.0 -typecheck \
  "$project_root/iina/MediaInfo/MediaInfoModels.swift" \
  "$project_root/iina/MediaInfo/VideoMediaInfoReader.swift"
