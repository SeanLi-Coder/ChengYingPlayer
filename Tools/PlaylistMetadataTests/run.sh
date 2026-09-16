#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-playlist-metadata.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -o "$test_dir/PlaylistMetadataTests" \
  "$project_root/iina/PlaylistFileMetadata.swift" \
  "$project_root/Tools/PlaylistMetadataTests/main.swift"
"$test_dir/PlaylistMetadataTests"
