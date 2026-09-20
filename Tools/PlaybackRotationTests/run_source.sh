#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source_cache="${SOURCE_CACHE_DIR:-$project_root/deps/sources}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-rotation-source.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
source "$project_root/other/playback_sources.sh"
source "$project_root/other/playback_patches.sh"
archive="$(fetch_playback_source mpv "$source_cache")"
tar -xf "$archive" -C "$test_dir"
mpv_source="$test_dir/mpv-$PLAYBACK_MPV_VERSION"

python3 -B "$project_root/Tools/PlaybackRotationTests/source_regression.py" \
  "$mpv_source" --expect-regression
apply_playback_patches "$test_dir" "$test_dir/build-record"
python3 -B "$project_root/Tools/PlaybackRotationTests/source_regression.py" "$mpv_source"
