#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-decoder-tests.XXXXXX")"
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
xcrun clang -fobjc-arc -fmodules -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
  -I deps/include Tools/NativeDecoderTests/main.m iina/NativePlayback/CYNMediaDecoder.m \
  deps/lib/libavcodec.61.dylib deps/lib/libavformat.61.dylib deps/lib/libavutil.59.dylib \
  deps/lib/libswresample.5.dylib deps/lib/libswscale.8.dylib \
  -Wl,-rpath,"$repo_root/deps/lib" -framework Foundation -framework CoreMedia \
  -framework CoreVideo -framework AudioToolbox -o "$test_dir/decoder-tests"
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i testsrc2=s=320x180:r=30:d=4 \
  -f lavfi -i sine=frequency=440:sample_rate=48000:duration=4 \
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
"$test_dir/decoder-tests" "$test_dir"
xcrun clang -fobjc-arc -fmodules -std=gnu11 -I deps/include -c \
  iina/NativePlayback/CYNMediaDecoder.m -o "$test_dir/decoder.o"
xcrun swiftc -parse-as-library -import-objc-header iina/NativePlayback/CYNMediaDecoder.h \
  Tools/NativeDecoderTests/SwiftEOF.swift "$test_dir/decoder.o" \
  deps/lib/libavcodec.61.dylib deps/lib/libavformat.61.dylib deps/lib/libavutil.59.dylib \
  deps/lib/libswresample.5.dylib deps/lib/libswscale.8.dylib \
  -Xlinker -rpath -Xlinker "$repo_root/deps/lib" -framework Foundation -framework CoreMedia \
  -framework CoreVideo -framework AudioToolbox -o "$test_dir/swift-eof-tests"
"$test_dir/swift-eof-tests" "$test_dir/av.mp4"
printf 'Artifacts: %s\n' "$test_dir"
