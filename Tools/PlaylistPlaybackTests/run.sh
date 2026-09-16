#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-playlist-playback.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -o "$test_dir/PlaylistPlaybackTests" \
  "$project_root/iina/Regex.swift" \
  "$project_root/iina/MPVPlaylistItem.swift" \
  "$project_root/iina/PlaylistPlaybackPolicy.swift" \
  "$project_root/Tools/PlaylistPlaybackTests/main.swift"
"$test_dir/PlaylistPlaybackTests" "$project_root"

if [[ -f "$project_root/deps/lib/libmpv.2.dylib" ]] && command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=24' \
    -f lavfi -i 'anullsrc=r=48000:cl=stereo' -t 20 -c:v mpeg4 -q:v 5 -c:a aac \
    "$test_dir/playback.mp4"
  xcrun swiftc -o "$test_dir/PlaylistMPVTests" \
    -import-objc-header "$project_root/deps/include/mpv/client.h" \
    "$project_root/iina/Regex.swift" \
    "$project_root/iina/MPVNode.swift" \
    "$project_root/iina/MPVPlaylistItem.swift" \
    "$project_root/iina/PlaylistPlaybackPolicy.swift" \
    "$project_root/Tools/PlaylistPlaybackTests/Integration/main.swift" \
    "$project_root/deps/lib/libmpv.2.dylib" \
    -Xlinker -rpath -Xlinker "$project_root/deps/lib"
  "$test_dir/PlaylistMPVTests" "$test_dir/playback.mp4"
else
  if [[ "${PLAYLIST_REQUIRE_LIVE_TESTS:-0}" == "1" ]]; then
    echo 'ERROR: Required live libmpv test dependencies are unavailable.' >&2
    exit 1
  fi
  echo 'SKIP: Live libmpv tests require fetched application dependencies and ffmpeg.'
fi
