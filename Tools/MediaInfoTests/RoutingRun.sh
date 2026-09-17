#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-media-routing.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -o "$test_dir/MediaInfoRoutingTests" \
  "$project_root/iina/MediaInfo/MediaInfoModels.swift" \
  "$project_root/iina/MediaInfo/MediaInfoCoordinator.swift" \
  "$project_root/Tools/MediaInfoTests/RoutingStubs.swift" \
  "$project_root/Tools/MediaInfoTests/RoutingTests.swift"
"$test_dir/MediaInfoRoutingTests"
