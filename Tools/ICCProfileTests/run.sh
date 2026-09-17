#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
library_dir="${ICC_PROFILE_LIBRARY_DIR:-$project_root/deps/lib}"
include_dir="${ICC_PROFILE_INCLUDE_DIR:-$project_root/deps/include}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-icc-profile.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
ulimit -c 0
python3 -B "$project_root/Tools/ICCProfileTests/check_wiring.py"
if [[ ! -f "$library_dir/libmpv.2.dylib" || ! -f "$include_dir/mpv/render.h" ]]; then
  echo 'ERROR: The actual source-built playback library and headers are required.' >&2
  exit 1
fi
xcrun clang -fobjc-arc -Wno-deprecated-declarations -Wall -Wextra -Werror -O2 \
  -I "$include_dir" "$project_root/Tools/ICCProfileTests/main.m" \
  "$library_dir/libmpv.2.dylib" -framework AppKit -framework OpenGL \
  -Wl,-rpath,"$library_dir" -o "$test_dir/ICCProfileTests"
# A child-side alarm survives exec and bounds deadlocks without masking signals.
/usr/bin/perl -e 'alarm 120; exec @ARGV or die "Unable to run ICC tests: $!";' \
  "$test_dir/ICCProfileTests" "$library_dir/libmpv.2.dylib" "$test_dir/reference.ppm"
