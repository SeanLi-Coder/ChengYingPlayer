#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/chengying-media-info-loader.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
bundle_bin="$test_root/Loader Test.app/Contents/MacOS"
mkdir -p "$bundle_bin"

xcrun swiftc -o "$bundle_bin/LoaderTests" \
  "$project_root/iina/MediaInfo/MediaInfoModels.swift" \
  "$project_root/iina/MediaInfo/ImageMediaInfoReader.swift" \
  "$project_root/iina/MediaInfo/VideoMediaInfoReader.swift" \
  "$project_root/iina/MediaInfo/MediaInfoLoader.swift" \
  "$project_root/Tools/MediaInfoTests/LoaderTests.swift"
cp "$project_root/deps/executable/ffprobe" "$bundle_bin/ffprobe"
"$project_root/deps/executable/ffmpeg" -hide_banner -loglevel error -nostdin \
  -f lavfi -i "testsrc2=size=160x90:rate=24:duration=0.25" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=0.25" \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest "$test_root/video sample.mp4"
"$bundle_bin/LoaderTests" "$test_root" real
xcrun clang -Wall -Wextra -Werror "$project_root/Tools/MediaInfoTests/LoaderProbeFixture.c" -o "$bundle_bin/ffprobe"
"$bundle_bin/LoaderTests" "$test_root" mutation
