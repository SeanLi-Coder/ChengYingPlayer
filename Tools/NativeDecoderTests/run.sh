#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-decoder-tests.XXXXXX")"
exec > >(tee "$test_dir/results.log") 2>&1
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
decoder_deps="${NATIVE_DECODER_DEPS:-$repo_root/deps}"
if [[ ! -d "$decoder_deps/include" || ! -d "$decoder_deps/lib" ]]; then
  printf 'NATIVE_DECODER_DEPS must contain readable include and lib directories.\n' >&2
  exit 2
fi
decoder_deps="$(cd "$decoder_deps" && pwd -P)"
decoder_libraries=(
  "$decoder_deps/lib/libavcodec.61.dylib" "$decoder_deps/lib/libavformat.61.dylib"
  "$decoder_deps/lib/libavutil.59.dylib" "$decoder_deps/lib/libswresample.5.dylib"
  "$decoder_deps/lib/libswscale.8.dylib"
)
for decoder_library in "${decoder_libraries[@]}"; do
  [[ -f "$decoder_library" && -r "$decoder_library" ]] || { printf 'Missing readable decoder library: %s\n' "$decoder_library" >&2; exit 2; }
done
[[ -r "$decoder_deps/include/libavcodec/avcodec.h" ]] || { printf 'Missing readable decoder SDK header.\n' >&2; exit 2; }
shasum -a 256 "${decoder_libraries[@]}" > "$test_dir/dependency-sha256.txt"
find -L "$decoder_deps/include" -type f -print0 > "$test_dir/header-paths.nul"
[[ -s "$test_dir/header-paths.nul" ]] || { printf 'Decoder SDK inventory is empty.\n' >&2; exit 2; }
while IFS= read -r -d '' decoder_header; do
  shasum -a 256 "$decoder_header" >> "$test_dir/dependency-sha256.txt"
done < "$test_dir/header-paths.nul"
printf 'Decoder dependency root: %s\n' "$decoder_deps"
verify_dependencies_on_exit() {
  local decoder_status=$?
  trap - EXIT
  if ! shasum -a 256 -c "$test_dir/dependency-sha256.txt" > "$test_dir/dependency-validation.log" 2>&1; then
    printf 'Decoder headers or linked libraries changed during testing.\n' >&2
    decoder_status=1
  fi
  exit "$decoder_status"
}
trap verify_dependencies_on_exit EXIT
decoder_source="$repo_root/iina/NativePlayback/CYNMediaDecoder.m"
clang_flags=(-g)
swift_flags=(-g)
case "${NATIVE_DECODER_SANITIZER:-}" in
  "") ;;
  address|thread) clang_flags+=("-fsanitize=$NATIVE_DECODER_SANITIZER" -g); swift_flags+=("-sanitize=$NATIVE_DECODER_SANITIZER" -g) ;;
  *) printf 'Unsupported NATIVE_DECODER_SANITIZER: use address or thread.\n' >&2; exit 2 ;;
esac
if [[ "${NATIVE_ORIGIN_SEEK_NEGATIVE:-0}" == 1 ]]; then
  python3 -B Tools/NativeDecoderTests/negative_origin_seek.py "$decoder_source" "$test_dir/CYNMediaDecoder.m"
  cp iina/NativePlayback/CYNMediaDecoder.h "$test_dir/CYNMediaDecoder.h"
  decoder_source="$test_dir/CYNMediaDecoder.m"
fi
shasum -a 256 "$decoder_source" iina/NativePlayback/CYNMediaDecoder.h \
  Tools/NativeDecoderTests/main.m Tools/NativeDecoderTests/OriginSeek.m Tools/NativeDecoderTests/SwiftEOF.swift \
  Tools/NativeDecoderTests/run.sh Tools/NativeDecoderTests/negative_origin_seek.py \
  > "$test_dir/source-sha256.txt"
printf 'Artifacts: %s\n' "$test_dir"
xcrun clang -fobjc-arc -fmodules -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
  "${clang_flags[@]}" -I "$decoder_deps/include" Tools/NativeDecoderTests/main.m "$decoder_source" \
  "${decoder_libraries[@]}" \
  -Wl,-rpath,"$decoder_deps/lib" -framework Foundation -framework CoreMedia \
  -framework CoreVideo -framework AudioToolbox -o "$test_dir/decoder-tests"
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i testsrc2=s=320x180:r=30:d=4 \
  -f lavfi -i sine=frequency=440:sample_rate=48000:duration=4 \
  -vf setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709 \
  -c:v libx264 -preset fast -bf 3 -g 30 -pix_fmt yuv420p -color_range tv \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a aac -y "$test_dir/av.mp4"
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i testsrc2=s=320x180:r=30:d=4 \
  -c:v ffv1 -pix_fmt yuv420p -color_range tv -y "$test_dir/software.mkv"
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i testsrc2=s=320x180:r=30:d=4 \
  -c:v ffv1 -pix_fmt yuv420p10le -color_range tv -y "$test_dir/software10.mkv"
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i testsrc2=s=320x180:r=30:d=4 \
  -vf setparams=range=full -c:v libx264 -preset fast -pix_fmt yuv420p -color_range pc -y "$test_dir/full.mp4"
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i testsrc2=s=320x180:r=30:d=4 \
  -vf format=yuv420p10le,setparams=range=full -c:v ffv1 -pix_fmt yuv420p10le -color_range pc -y "$test_dir/full10.mkv"
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i testsrc2=s=320x180:r=30:d=0.2 \
  -c:v ffv1 -pix_fmt yuv420p12le -y "$test_dir/software12.mkv"
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i testsrc2=s=320x180:r=30:d=0.2 \
  -c:v ffv1 -pix_fmt yuv444p10le -y "$test_dir/software444.mkv"
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i testsrc2=s=320x180:r=30:d=4 \
  -vf format=yuv420p10le,setparams=range=limited:color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc \
  -c:v libx265 -preset fast -x265-params log-level=error:pools=2:frame-threads=2:colorprim=9:transfer=16:colormatrix=9 \
  -pix_fmt yuv420p10le -color_range tv -color_primaries bt2020 \
  -color_trc smpte2084 -colorspace bt2020nc -y "$test_dir/hdr.mkv"
"$ffmpeg_bin" -hide_banner -loglevel error -i "$test_dir/av.mp4" -c copy \
  -output_ts_offset 5 -y "$test_dir/offset.mp4"
"$ffmpeg_bin" -hide_banner -loglevel error -display_rotation:v:0 90 -i "$test_dir/av.mp4" -c copy \
  -y "$test_dir/rotated.mp4"
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i anullsrc=r=48000:cl=5.1 \
  -t 2 -c:a pcm_f32le -y "$test_dir/surround.wav"
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i sine=frequency=440:sample_rate=48000:duration=0.2 \
  -c:a pcm_s24le -y "$test_dir/audio24.wav"
"$ffmpeg_bin" -hide_banner -loglevel error -i "$test_dir/audio24.wav" -c:a pcm_s32le -y "$test_dir/audio32.wav"
"$ffmpeg_bin" -hide_banner -loglevel error -i "$test_dir/av.mp4" \
  -i Tools/NativeDecoderTests/fixtures/subtitles.srt -i Tools/NativeDecoderTests/fixtures/chapters.ffmeta \
  -map 0:v:0 -map 0:v:0 -map 0:a:0 -map 0:a:0 -map 1:0 -map_chapters 2 \
  -c copy -y "$test_dir/inventory.mkv"
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i testsrc2=s=320x180:r=30:d=0.2 \
  -vf setsar=4/3 -c:v libx264 -preset fast -pix_fmt yuv420p -y "$test_dir/aspect.mp4"
"$ffmpeg_bin" -hide_banner -loglevel error -display_rotation:v:0 90 -i "$test_dir/aspect.mp4" \
  -c copy -y "$test_dir/aspect-rotated.mp4"
"$ffmpeg_bin" -hide_banner -loglevel error -i "$test_dir/aspect.mp4" -c copy \
  -aspect 2:1 -y "$test_dir/aspect-override.mp4"
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i testsrc2=s=320x180:r=30:d=0.2 \
  -vf format=yuv420p10le,setparams=range=limited:color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc \
  -c:v libx265 -preset fast \
  -x265-params 'log-level=error:pools=2:frame-threads=2:colorprim=9:transfer=16:colormatrix=9:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,200' \
  -pix_fmt yuv420p10le -color_range tv -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  -y "$test_dir/static-hdr.mkv"
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i color=c=blue:s=64x64:r=1:d=1 \
  -frames:v 1 -c:v mjpeg -y "$test_dir/cover.jpg"
"$ffmpeg_bin" -hide_banner -loglevel error -i "$test_dir/audio24.wav" -i "$test_dir/cover.jpg" \
  -map 0:a:0 -map 1:v:0 -c:a aac -c:v copy -disposition:v:0 attached_pic -y "$test_dir/cover.m4a"
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i color=red:s=160x90:r=30:d=3 \
  -f lavfi -i sine=frequency=330:sample_rate=48000:duration=4 \
  -vf setpts=PTS+1/TB -fps_mode passthrough -c:v ffv1 -pix_fmt yuv420p \
  -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -ac 2 -c:a pcm_f32le "$test_dir/delayed-seek.mkv"
"$ffmpeg_bin" -hide_banner -loglevel error -i "$test_dir/delayed-seek.mkv" \
  -fps_mode passthrough -c:v libx264 -preset fast -crf 0 -bf 8 -g 30 -pix_fmt yuv420p \
  -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a aac "$test_dir/delayed-seek.mp4"
"$ffmpeg_bin" -hide_banner -loglevel error -i "$test_dir/delayed-seek.mp4" -c copy \
  -output_ts_offset 5 "$test_dir/delayed-seek-offset.mp4"
"$test_dir/decoder-tests" "$test_dir"
xcrun clang -fobjc-arc -fmodules -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
  "${clang_flags[@]}" -I "$decoder_deps/include" Tools/NativeDecoderTests/OriginSeek.m "$decoder_source" \
  "${decoder_libraries[@]}" \
  -Wl,-rpath,"$decoder_deps/lib" -framework Foundation -framework CoreMedia \
  -framework CoreVideo -framework AudioToolbox -o "$test_dir/origin-seek-tests"
"$test_dir/origin-seek-tests" "$test_dir"
xcrun clang -fobjc-arc -fmodules -std=gnu11 -I "$decoder_deps/include" -c \
  "${clang_flags[@]}" "$decoder_source" -o "$test_dir/decoder.o"
xcrun swiftc -parse-as-library -import-objc-header iina/NativePlayback/CYNMediaDecoder.h \
  "${swift_flags[@]}" Tools/NativeDecoderTests/SwiftEOF.swift "$test_dir/decoder.o" \
  "${decoder_libraries[@]}" \
  -Xlinker -rpath -Xlinker "$decoder_deps/lib" -framework Foundation -framework CoreMedia \
  -framework CoreVideo -framework AudioToolbox -o "$test_dir/swift-eof-tests"
"$test_dir/swift-eof-tests" "$test_dir/av.mp4"
shasum -a 256 -c "$test_dir/source-sha256.txt"
printf 'Artifacts: %s\n' "$test_dir"
