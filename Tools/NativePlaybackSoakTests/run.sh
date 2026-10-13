#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-playback-soak.XXXXXX")"
printf 'Artifacts: %s\n' "$test_dir"
# Validate identities even after a compiler, fixture, runtime or timeout failure.
# Only this run's compiled products are retired; diagnostics and fixtures remain.
finalize() {
  local result=$? validation=0 status
  trap - EXIT
  set +e
  if [[ -f "$test_dir/source-sha256.txt" ]]; then
    /usr/bin/shasum -a 256 -c "$test_dir/source-sha256.txt" > "$test_dir/source-validation.log" 2>&1
    status=$?; if (( status != 0 )); then validation=1; fi
    /usr/bin/shasum -a 256 "${source_inputs[@]}" > "$test_dir/source-sha256-after.txt" 2>&1
    status=$?; if (( status != 0 )); then validation=1; fi
  fi
  if [[ -f "$test_dir/generated-sha256.txt" ]]; then
    /usr/bin/shasum -a 256 -c "$test_dir/generated-sha256.txt" > "$test_dir/generated-validation.log" 2>&1
    status=$?; if (( status != 0 )); then validation=1; fi
    /usr/bin/shasum -a 256 "${generated_inputs[@]}" > "$test_dir/generated-sha256-after.txt" 2>&1
    status=$?; if (( status != 0 )); then validation=1; fi
  fi
  if [[ -f "$test_dir/dependency-sha256.txt" ]]; then
    validate_native_test_dependencies 2> "$test_dir/dependency-validation-errors.log"
    status=$?; if (( status != 0 )); then validation=1; fi
    if [[ "${dependency_inventory_complete:-0}" == 1 ]]; then
      /usr/bin/find -L "$native_test_deps/include" -type f -print0 | \
        /usr/bin/xargs -0 /usr/bin/shasum -a 256 > "$test_dir/dependency-sha256-after.txt"
      status=$?; if (( status != 0 )); then validation=1; fi
      /usr/bin/shasum -a 256 "${native_test_libraries[@]}" "${dependency_extra_inputs[@]}" \
        >> "$test_dir/dependency-sha256-after.txt"
      status=$?; if (( status != 0 )); then validation=1; fi
      diff -u "$test_dir/dependency-sha256.txt" "$test_dir/dependency-sha256-after.txt" \
        > "$test_dir/dependency-inventory-diff.log"
      status=$?; if (( status != 0 )); then validation=1; fi
    fi
  fi
  printf '%s\n' "$validation" > "$test_dir/identity-exit-status.txt"
  if (( validation != 0 )); then
    printf 'ERROR: Input identity changed or could not be verified; see validation logs.\n' >&2
    result=1
  fi
  rm -f "$test_dir/soak-tests" "$test_dir/decoder.o" "$test_dir/memory.o"
  status=$?; if (( status != 0 )); then result=1; fi
  printf '%s\n' "$result" > "$test_dir/exit-status.txt"
  printf 'Runner exit: %s; artifacts: %s\n' "$result" "$test_dir"
  exit "$result"
}
trap finalize EXIT
run_logged() {
  local destination=$1
  shift
  set +e
  "$@" 2>&1 | tee "$test_dir/$destination.log"
  local pipeline_status=("${PIPESTATUS[@]}")
  set -e
  printf '%s\n' "${pipeline_status[0]}" > "$test_dir/$destination-exit-status.txt"
  printf '%s\n' "${pipeline_status[1]}" > "$test_dir/$destination-tee-exit-status.txt"
  if (( pipeline_status[0] != 0 )); then return "${pipeline_status[0]}"; fi
  return "${pipeline_status[1]}"
}
seconds="${NATIVE_SOAK_SECONDS:-180}"
case "$seconds" in
  ''|*[!0-9]*) echo 'ERROR: NATIVE_SOAK_SECONDS must be an integer.' >&2; exit 2 ;;
esac
if (( seconds < 60 || seconds > 1800 )); then
  echo 'ERROR: NATIVE_SOAK_SECONDS must be between 60 and 1800.' >&2
  exit 2
fi
negative_control="${NATIVE_SOAK_WRONG_REFERENCE:-0}"
case "$negative_control" in
  0|1) ;;
  *) echo 'ERROR: NATIVE_SOAK_WRONG_REFERENCE must be 0 or 1.' >&2; exit 2 ;;
esac
ffmpeg="$repo_root/deps/executable/ffmpeg"
test_sources="$repo_root/Tools/NativePlaybackSoakTests"
source_inputs=(iina/NativePlayback/CYNMediaDecoder.h iina/NativePlayback/CYNMediaDecoder.m
  iina/NativePlayback/NativeSampleBufferOutput.swift iina/NativePlayback/NativePlaybackSampleGate.swift
  iina/NativePlayback/NativePlaybackSession.swift iina/NativePlayback/NativePlaybackSurface.swift
  Tools/NativePlaybackSoakTests/Memory.h Tools/NativePlaybackSoakTests/Memory.c
  Tools/NativePlaybackSoakTests/main.swift Tools/NativePlaybackSoakTests/run.sh
  Tools/RenderTestSupport/native_dependencies.sh Tools/RenderTestSupport/verify_native_dependencies.py
  other/verify_playback_distribution.py "$ffmpeg")
/usr/bin/shasum -a 256 "${source_inputs[@]}" > "$test_dir/source-sha256.txt"
# shellcheck source=Tools/RenderTestSupport/native_dependencies.sh
source "$repo_root/Tools/RenderTestSupport/native_dependencies.sh"
prepare_native_test_dependencies > "$test_dir/dependency-preparation.log" 2>&1
verify_native_test_runtime 2> "$test_dir/dependency-runtime-errors.log"
/usr/bin/shasum -a 256 "$native_test_deps/playback-build-record/library-sha256.txt" \
  "$native_test_deps/playback-build-record/headers-sha256.txt" >> "$test_dir/dependency-sha256.txt"
dependency_extra_inputs=("$native_test_deps/lib/libavdevice.61.dylib" "$native_test_deps/lib/libavfilter.10.dylib"
  "$native_test_deps/lib/libpostproc.58.dylib" "$native_test_deps/lib/libmpv.2.dylib"
  "$native_test_deps/playback-build-record/library-sha256.txt" "$native_test_deps/playback-build-record/headers-sha256.txt")
dependency_inventory_complete=1
printf 'seconds=%s\nwrong_reference=%s\nffmpeg=%s\ndependencies=%s\n' \
  "$seconds" "$negative_control" "$ffmpeg" "$native_test_deps" > "$test_dir/mode.txt"
printf 'Playback dependencies: %s\n' "$native_test_deps"
run_logged compile-decoder xcrun clang -target arm64-apple-macos12 -fobjc-arc -fmodules -std=gnu11 -I "$native_test_deps/include" -c \
  iina/NativePlayback/CYNMediaDecoder.m -o "$test_dir/decoder.o"
run_logged compile-memory xcrun clang -target arm64-apple-macos14.4 -x objective-c -fobjc-arc -Wall -Wextra -Werror -I iina/NativePlayback \
  -c "$test_sources/Memory.c" -o "$test_dir/memory.o"
run_logged compile-soak xcrun swiftc -swift-version 5 -target arm64-apple-macos14.4 \
  -import-objc-header "$test_sources/Memory.h" -I iina/NativePlayback \
  iina/NativePlayback/NativeSampleBufferOutput.swift \
  iina/NativePlayback/NativePlaybackSampleGate.swift \
  iina/NativePlayback/NativePlaybackSession.swift \
  iina/NativePlayback/NativePlaybackSurface.swift \
  "$test_sources/main.swift" "$test_dir/decoder.o" "$test_dir/memory.o" \
  "${native_test_libraries[@]}" \
  -Xlinker -rpath -Xlinker "$native_test_deps/lib" \
  -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework AudioToolbox -o "$test_dir/soak-tests"
/usr/bin/shasum -a 256 -c "$test_dir/source-sha256.txt" > "$test_dir/source-preflight-validation.log"
echo 'Generating isolated 4K H.264/AAC and HEVC Main10/AAC fixtures.'
run_logged fixture-h264 "$ffmpeg" -hide_banner -loglevel error -nostdin \
  -f lavfi -i 'color=red:s=3840x2160:r=24:d=2[a];color=lime:s=3840x2160:r=24:d=2[b];color=blue:s=3840x2160:r=24:d=2[c];color=magenta:s=3840x2160:r=24:d=2[d];[a][b][c][d]concat=n=4:v=1:a=0' \
  -f lavfi -i 'anullsrc=r=48000:cl=stereo' -t 8 \
  -c:v libx264 -preset ultrafast -crf 0 -threads 4 -g 24 -bf 3 -pix_fmt yuv420p \
  -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a aac -movflags +faststart "$test_dir/h264.mp4"
run_logged fixture-hevc "$ffmpeg" -hide_banner -loglevel error -nostdin -i "$test_dir/h264.mp4" \
  -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le \
  -x265-params 'lossless=1:log-level=error:pools=4:frame-threads=2:keyint=24' \
  -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -tag:v hvc1 -c:a copy -movflags +faststart "$test_dir/hevc-main10.mp4"
# Read reference pixels independently with FFmpeg. The test checks retained YUV
# code values, not a claim that synthetic color labels certify physical color.
for fixture in h264.mp4 hevc-main10.mp4; do
  bits=8; pixel_format=yuv420p; units=tu1
  if [[ "$fixture" == hevc-main10.mp4 ]]; then bits=10; pixel_format=yuv420p10le; units=tu2; fi
  for point in '0|0.25' '1|2.25' '2|4.25' '3|6.25'; do
    phase="${point%%|*}"; position="${point#*|}"
    bytes="$("$ffmpeg" -hide_banner -loglevel error -nostdin -ss "$position" \
      -i "$test_dir/$fixture" -vf 'crop=2:2:8:8' -frames:v 1 -f rawvideo \
      -pix_fmt "$pixel_format" - 2>> "$test_dir/reference-decoding.log" | od -An -"$units" | xargs)"
    printf '%s\t%s\t%s\t%s\n' "$fixture" "$phase" "$bits" "$bytes" >> "$test_dir/references.tsv"
  done
done
generated_inputs=("$test_dir/decoder.o" "$test_dir/memory.o" "$test_dir/soak-tests"
  "$test_dir/h264.mp4" "$test_dir/hevc-main10.mp4" "$test_dir/references.tsv")
/usr/bin/shasum -a 256 "${generated_inputs[@]}" > "$test_dir/generated-sha256.txt"
run_logged results /usr/bin/perl -e '$seconds = shift @ARGV; alarm($seconds + 150); exec @ARGV' "$seconds" \
  "$test_dir/soak-tests" "$test_dir" "$seconds"
