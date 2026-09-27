#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
deps_dir="${1:-$project_root/deps}"
source_cache="${SOURCE_CACHE_DIR:-$project_root/deps/sources}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-hdr-source.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
source "$project_root/other/playback_sources.sh"
source "$project_root/other/playback_patches.sh"

for component in mpv libplacebo fast-float playback-jinja playback-markupsafe playback-vulkan-headers; do
  archive="$(fetch_playback_source "$component" "$source_cache")"
  tar -xf "$archive" -C "$test_dir"
done
placebo_source="$test_dir/libplacebo-$PLAYBACK_PLACEBO_VERSION"
cp -R "$test_dir/fast_float-$PLAYBACK_FAST_FLOAT_COMMIT/include" "$placebo_source/3rdparty/fast_float/"
cp -R "$test_dir/jinja-$PLAYBACK_JINJA_COMMIT/src" "$placebo_source/3rdparty/jinja/"
cp -R "$test_dir/markupsafe-$PLAYBACK_MARKUPSAFE_COMMIT/src" "$placebo_source/3rdparty/markupsafe/"
cp -R "$test_dir/Vulkan-Headers-$PLAYBACK_VULKAN_HEADERS_COMMIT/include" "$placebo_source/3rdparty/Vulkan-Headers/"
prefix="$test_dir/install"
# No system libplacebo or FFmpeg may replace the checksum-pinned test inputs.
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
meson setup "$test_dir/placebo-build" "$placebo_source" \
  --prefix "$prefix" --libdir lib --buildtype release --wrap-mode nofallback \
  -Ddefault_library=static -Dauto_features=disabled -Ddemos=false -Dtests=false -Ddovi=enabled
meson compile -C "$test_dir/placebo-build" -j 4
meson install -C "$test_dir/placebo-build"

mpv_source="$test_dir/mpv-$PLAYBACK_MPV_VERSION"
python3 -B "$project_root/Tools/HDRSourceTests/source_regression.py" \
  "$mpv_source" "$prefix" "$deps_dir" --expect-regression
apply_playback_patches "$test_dir" "$test_dir/build-record"
python3 -B "$project_root/Tools/HDRSourceTests/source_regression.py" \
  "$mpv_source" "$prefix" "$deps_dir"
