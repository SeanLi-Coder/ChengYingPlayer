#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
library_dir="${HDR_RENDERING_LIBRARY_DIR:-$project_root/deps/lib}"
include_dir="${HDR_RENDERING_INCLUDE_DIR:-$project_root/deps/include}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-hdr-rendering.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
ulimit -c 0

xcrun clang -std=c11 -Wall -Wextra -Werror -O2 -I "$include_dir" \
  "$project_root/Tools/HDRRenderingTests/fixture.c" \
  "$library_dir/libavcodec.61.dylib" "$library_dir/libavformat.61.dylib" \
  "$library_dir/libavutil.59.dylib" -Wl,-rpath,"$library_dir" -o "$test_dir/GenerateHDRFixture"
xcrun clang -fobjc-arc -Wno-deprecated-declarations -Wall -Wextra -Werror -O2 \
  -I "$include_dir" "$project_root/Tools/HDRRenderingTests/main.m" \
  "$library_dir/libmpv.2.dylib" -framework AppKit -framework OpenGL \
  -Wl,-rpath,"$library_dir" -o "$test_dir/HDRRenderingTests"

for gamma in srgb pq hlg; do
  "$test_dir/GenerateHDRFixture" "$gamma" "$test_dir/$gamma.mkv"
  /usr/bin/perl -e 'alarm 90; exec @ARGV or die "Unable to run HDR tests: $!";' \
    "$test_dir/HDRRenderingTests" "$library_dir/libmpv.2.dylib" \
    "$test_dir/$gamma.mkv" "$test_dir/$gamma.ppm" "$gamma"
done
python3 -B "$project_root/Tools/HDRRenderingTests/check_pixels.py" \
  "$test_dir/srgb.ppm" "$test_dir/pq.ppm" "$test_dir/hlg.ppm"
