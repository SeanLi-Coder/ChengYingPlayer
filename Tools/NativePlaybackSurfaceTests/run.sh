#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-surface-tests.XXXXXX")"
trap 'rm -f "$test_dir/surface-tests" "$test_dir/decoder.o"' EXIT
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
xcrun clang -target arm64-apple-macos12 -fobjc-arc -fmodules -std=gnu11 -I deps/include -c \
  iina/NativePlayback/CYNMediaDecoder.m -o "$test_dir/decoder.o"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.4 \
  -import-objc-header iina/NativePlayback/CYNMediaDecoder.h \
  iina/NativePlayback/NativeSampleBufferOutput.swift \
  iina/NativePlayback/NativePlaybackSampleGate.swift \
  iina/NativePlayback/NativePlaybackSession.swift \
  iina/NativePlayback/NativePlaybackSurface.swift \
  Tools/NativePlaybackSurfaceTests/main.swift "$test_dir/decoder.o" \
  deps/lib/libavcodec.61.dylib deps/lib/libavformat.61.dylib deps/lib/libavutil.59.dylib \
  deps/lib/libswresample.5.dylib deps/lib/libswscale.8.dylib \
  -Xlinker -rpath -Xlinker "$repo_root/deps/lib" \
  -framework AppKit -framework AVFoundation -framework CoreMedia \
  -framework CoreVideo -framework AudioToolbox -o "$test_dir/surface-tests"
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i 'nullsrc=s=64x48:r=10:d=1' \
  -vf "geq=lum='if(lt(Y,H/2),if(lt(X,W/2),63,173),if(lt(X,W/2),32,219))':cb='if(lt(Y,H/2),if(lt(X,W/2),102,42),if(lt(X,W/2),240,16))':cr='if(lt(Y,H/2),if(lt(X,W/2),240,26),if(lt(X,W/2),118,138))',setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709" \
  -c:v libx264 -crf 0 -pix_fmt yuv420p -color_range tv -color_primaries bt709 \
  -color_trc bt709 -colorspace bt709 "$test_dir/base.mp4"
for angle in 0 90 180 270; do
  "$ffmpeg_bin" -hide_banner -loglevel error -display_rotation "$angle" -i "$test_dir/base.mp4" -map 0:v:0 \
    -c copy "$test_dir/rotation-$angle.mp4"
  "$ffmpeg_bin" -hide_banner -loglevel error -i "$test_dir/rotation-$angle.mp4" \
    -frames:v 1 -pix_fmt yuv420p -f rawvideo "$test_dir/reference-$angle.yuv"
done
for point in '16:12|63 63 63 63 102 240' '48:12|173 173 173 173 42 26' \
  '16:36|32 32 32 32 240 118' '48:36|219 219 219 219 16 138'; do
  position="${point%%|*}"
  expected="${point#*|}"
  actual="$("$ffmpeg_bin" -hide_banner -loglevel error -i "$test_dir/base.mp4" \
    -vf "crop=2:2:$position" -frames:v 1 -pix_fmt yuv420p -f rawvideo - | od -An -tu1 | xargs)"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: Independent source quadrant bytes differ: %s: %s\n' "$position" "$actual" >&2
    exit 1
  fi
done
printf 'Artifacts: %s\n' "$test_dir"
/usr/bin/perl -e 'alarm 60; exec @ARGV' "$test_dir/surface-tests" "$test_dir" 2>&1 | tee "$test_dir/results.log"
