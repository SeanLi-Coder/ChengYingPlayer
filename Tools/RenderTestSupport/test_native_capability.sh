#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-native-capability.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun clang -std=c11 -Wall -Wextra -Werror -O2 \
  -DCGLChoosePixelFormat=unavailable_test_pixel_format \
  -I "$project_root/deps/include" \
  "$project_root/Tools/PlaybackSoakTests/main.c" \
  "$project_root/Tools/RenderTestSupport/UnavailableCGL.c" \
  "$project_root/deps/lib/libmpv.2.dylib" \
  -framework OpenGL -framework CoreFoundation \
  -Wl,-rpath,"$project_root/deps/lib" -o "$test_dir/NativeCapability"

for mode in hardware software; do
  status=0
  "$test_dir/NativeCapability" /not-opened-h264 /not-opened-hevc 60 "$mode" \
    "$project_root/deps/lib/libavcodec.61.dylib" > "$test_dir/$mode.log" 2>&1 || status=$?
  expected_status=1
  expected_attempts=1
  if [[ "$mode" == software ]]; then
    expected_status=77
    expected_attempts=2
  fi
  if (( status != expected_status )) || [[ "$(grep -c '^BOUNDARY:' "$test_dir/$mode.log")" != "$expected_attempts" ]]; then
    sed -n '1,80p' "$test_dir/$mode.log" >&2
    echo "FAIL: Native $mode context failure classification changed." >&2
    exit 1
  fi
done
echo 'PASS: Actual soak harness keeps hardware context failure fatal and classifies only initial software context absence as capability status 77 (mock CGL boundary, not a rendering pass).'
