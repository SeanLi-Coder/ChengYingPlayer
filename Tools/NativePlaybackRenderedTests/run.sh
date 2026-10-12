#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-playback-rendered-tests.XXXXXX")"
trap 'rm -f "$test_dir/rendered-tests" "$test_dir/decoder.o"' EXIT
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
session_source="${NATIVE_PLAYBACK_SESSION_SOURCE:-iina/NativePlayback/NativePlaybackSession.swift}"
xcrun clang -target arm64-apple-macos12 -fobjc-arc -fmodules -std=gnu11 -I deps/include -c \
  iina/NativePlayback/CYNMediaDecoder.m -o "$test_dir/decoder.o"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.4 \
  -import-objc-header iina/NativePlayback/CYNMediaDecoder.h \
  iina/NativePlayback/NativeSampleBufferOutput.swift \
  iina/NativePlayback/NativePlaybackSampleGate.swift \
  "$session_source" \
  Tools/NativePlaybackRenderedTests/main.swift "$test_dir/decoder.o" \
  deps/lib/libavcodec.61.dylib deps/lib/libavformat.61.dylib deps/lib/libavutil.59.dylib \
  deps/lib/libswresample.5.dylib deps/lib/libswscale.8.dylib \
  -Xlinker -rpath -Xlinker "$repo_root/deps/lib" \
  -framework AppKit -framework AVFoundation -framework CoreMedia \
  -framework CoreVideo -framework AudioToolbox -o "$test_dir/rendered-tests"
"$ffmpeg_bin" -hide_banner -loglevel error \
  -f lavfi -i 'nullsrc=s=160x90:r=30:d=3.6' \
  -f lavfi -i 'anullsrc=r=48000:cl=stereo:d=3.6' \
  -vf "geq=lum='if(lt(T,1.2),63,if(lt(T,2.4),173,32))':cb='if(lt(T,1.2),102,if(lt(T,2.4),42,240))':cr='if(lt(T,1.2),240,if(lt(T,2.4),26,118))',setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709" \
  -c:v ffv1 -pix_fmt yuv420p -color_range tv -color_primaries bt709 \
  -color_trc bt709 -colorspace bt709 -c:a pcm_f32le "$test_dir/timeline.mkv"
"$ffmpeg_bin" -hide_banner -loglevel error -i "$test_dir/timeline.mkv" \
  -c:v libx264 -preset fast -crf 0 -bf 3 -g 30 -pix_fmt yuv420p \
  -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a aac "$test_dir/timeline.mp4"
"$ffmpeg_bin" -hide_banner -loglevel error \
  -f lavfi -i 'nullsrc=s=160x90:r=30:d=3.6' \
  -f lavfi -i 'anullsrc=r=48000:cl=stereo:d=3.6' \
  -vf 'geq=lum=78:cb=214:cr=230,setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709' -c:v ffv1 -pix_fmt yuv420p \
  -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a pcm_f32le "$test_dir/alternate.mkv"
for fixture in timeline.mkv timeline.mp4; do
  for point in '0.2|63 63 63 63 102 240' '1.7|173 173 173 173 42 26' '2.9|32 32 32 32 240 118'; do
    sample_time="${point%%|*}"
    expected_bytes="${point#*|}"
    actual_bytes="$("$ffmpeg_bin" -hide_banner -loglevel error -ss "$sample_time" \
      -i "$test_dir/$fixture" -vf 'crop=2:2:8:8' -frames:v 1 -f rawvideo -pix_fmt yuv420p - | od -An -tu1 | xargs)"
    if [[ "$actual_bytes" != "$expected_bytes" ]]; then
      printf 'FAIL: Independent fixture bytes differ: %s at %s: %s\n' "$fixture" "$sample_time" "$actual_bytes" >&2
      exit 1
    fi
  done
done
alternate_bytes="$("$ffmpeg_bin" -hide_banner -loglevel error -i "$test_dir/alternate.mkv" \
  -vf 'crop=2:2:8:8' -frames:v 1 -f rawvideo -pix_fmt yuv420p - | od -An -tu1 | xargs)"
if [[ "$alternate_bytes" != '78 78 78 78 214 230' ]]; then
  printf 'FAIL: Independent alternate fixture bytes differ: %s\n' "$alternate_bytes" >&2
  exit 1
fi
printf 'Artifacts: %s\n' "$test_dir"
printf 'Session source: %s\n' "$session_source"
/usr/bin/perl -e 'alarm 65; exec @ARGV' "$test_dir/rendered-tests" "$test_dir" 2>&1 | tee "$test_dir/results.log"
