#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
deps_dir="${1:-$project_root/deps}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-playback-mode.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

for dependency in "$deps_dir/executable/ffmpeg" "$deps_dir/lib/libmpv.2.dylib" "$deps_dir/include/mpv/client.h"; do
  if [[ ! -f "$dependency" ]]; then
    echo "ERROR: Playback mode tests require $dependency" >&2
    exit 1
  fi
done

for color in red blue; do
  "$deps_dir/executable/ffmpeg" -hide_banner -loglevel error -nostdin \
    -f lavfi -i "color=$color:size=160x90:rate=24" -t 1.25 \
    -an -c:v mpeg4 -q:v 5 "$test_dir/$color.mp4"
done

xcrun swift "$project_root/Tools/PlaybackModeLiveTests/extract.swift" "$project_root" "$test_dir"
xcrun swiftc -o "$test_dir/PlaybackModeLiveTests" \
  -import-objc-header "$deps_dir/include/mpv/client.h" \
  "$project_root/iina/MPVOption.swift" \
  "$project_root/iina/MPVHook.swift" \
  "$project_root/iina/PlaylistPlaybackPolicy.swift" \
  "$test_dir/Player.swift" \
  "$project_root/Tools/PlaybackModeLiveTests/main.swift" \
  "$deps_dir/lib/libmpv.2.dylib" -Xlinker -rpath -Xlinker "$deps_dir/lib"
"$test_dir/PlaybackModeLiveTests" "$test_dir"
