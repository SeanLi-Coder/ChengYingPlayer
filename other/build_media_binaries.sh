#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_ROOT/deps/executable}"
SOURCE_CACHE_DIR="${SOURCE_CACHE_DIR:-$PROJECT_ROOT/deps/sources}"
ARCHITECTURE="${ARCHS:-$(uname -m)}"

# shellcheck source=other/third_party_sources.sh
source "$SCRIPT_DIR/third_party_sources.sh"
# shellcheck source=other/build_subtitle_libraries.sh
source "$SCRIPT_DIR/build_subtitle_libraries.sh"

case "$ARCHITECTURE" in
  arm64)
    DEFAULT_DEPLOYMENT_TARGET="12.0"
    ;;
  x86_64)
    DEFAULT_DEPLOYMENT_TARGET="10.15"
    ;;
  *)
    echo "Unsupported architecture: $ARCHITECTURE" >&2
    exit 2
    ;;
esac

DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-$DEFAULT_DEPLOYMENT_TARGET}"

version_number() {
  local version="$1"
  local major=""
  local minor="0"
  local patch="0"

  if [[ ! "$version" =~ ^([0-9]+)(\.([0-9]+))?(\.([0-9]+))?$ ]]; then
    echo "Invalid macOS deployment target: $version" >&2
    return 1
  fi

  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[3]:-0}"
  patch="${BASH_REMATCH[5]:-0}"
  printf '%d\n' "$((10#$major * 1000000 + 10#$minor * 1000 + 10#$patch))"
}

target_version_number="$(version_number "$DEPLOYMENT_TARGET")" || exit 2
minimum_version_number="$(version_number "$DEFAULT_DEPLOYMENT_TARGET")" || exit 2
if (( target_version_number < minimum_version_number )); then
  echo "$ARCHITECTURE builds require macOS $DEFAULT_DEPLOYMENT_TARGET or later; got $DEPLOYMENT_TARGET." >&2
  exit 2
fi

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
TARGET_CFLAGS="-arch $ARCHITECTURE -mmacosx-version-min=$DEPLOYMENT_TARGET"
TARGET_LDFLAGS="-arch $ARCHITECTURE -mmacosx-version-min=$DEPLOYMENT_TARGET"

for command_name in clang cmake curl libtool make otool pkg-config shasum tar; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required build command is unavailable: $command_name" >&2
    exit 2
  fi
done

if [[ "$ARCHITECTURE" == "x86_64" ]] && ! command -v nasm >/dev/null 2>&1; then
  echo "nasm is required for the x86_64 codec build." >&2
  exit 2
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chengying-media-runtime.XXXXXX")"
FFMPEG_ARCHIVE="$(fetch_verified_source ffmpeg "$SOURCE_CACHE_DIR")"
X264_ARCHIVE="$(fetch_verified_source x264 "$SOURCE_CACHE_DIR")"
X265_ARCHIVE="$(fetch_verified_source x265 "$SOURCE_CACHE_DIR")"
FFMPEG_SOURCE_DIR="$WORK_DIR/ffmpeg-$FFMPEG_VERSION"
X264_SOURCE_DIR="$WORK_DIR/x264-$X264_COMMIT"
X265_SOURCE_DIR="$WORK_DIR/x265_$X265_VERSION"
X264_PREFIX="$WORK_DIR/x264-install"
X265_PREFIX="$WORK_DIR/x265-install"
SUBTITLE_PREFIX="$WORK_DIR/subtitle-install"
INSTALL_PREFIX="$WORK_DIR/ffmpeg-install"

cleanup() {
  if [[ -n "${WORK_DIR:-}" && "$WORK_DIR" == "${TMPDIR:-/tmp}"/chengying-media-runtime.* ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

tar -xf "$FFMPEG_ARCHIVE" -C "$WORK_DIR"
tar -xf "$X264_ARCHIVE" -C "$WORK_DIR"
tar -xf "$X265_ARCHIVE" -C "$WORK_DIR"
mkdir -p "$OUTPUT_DIR"

echo "Building static subtitle rendering libraries..."
build_subtitle_libraries "$SUBTITLE_PREFIX"

echo "Building x264 $X264_VERSION ($X264_COMMIT)..."
cd "$X264_SOURCE_DIR"
CC=clang ./configure \
  --prefix="$X264_PREFIX" \
  --extra-cflags="$TARGET_CFLAGS" \
  --extra-ldflags="$TARGET_LDFLAGS" \
  --disable-cli \
  --disable-lsmash \
  --disable-swscale \
  --disable-ffms \
  --disable-opencl \
  --enable-static \
  --enable-pic
make -j"$(sysctl -n hw.logicalcpu)"
make install

echo "Building x265 $X265_VERSION with 8-bit, 10-bit, and 12-bit support..."
X265_COMMON_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$X265_PREFIX"
  -DCMAKE_OSX_ARCHITECTURES="$ARCHITECTURE"
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
  -DENABLE_CLI=OFF
  -DENABLE_SHARED=OFF
)
X265_HIGH_BIT_DEPTH_ARGS=(
  "${X265_COMMON_ARGS[@]}"
  -DHIGH_BIT_DEPTH=ON
  -DEXPORT_C_API=OFF
)

cmake -S "$X265_SOURCE_DIR/source" -B "$WORK_DIR/x265-10bit" \
  "${X265_HIGH_BIT_DEPTH_ARGS[@]}"
cmake --build "$WORK_DIR/x265-10bit" --parallel "$(sysctl -n hw.logicalcpu)"

cmake -S "$X265_SOURCE_DIR/source" -B "$WORK_DIR/x265-12bit" \
  "${X265_HIGH_BIT_DEPTH_ARGS[@]}" \
  -DMAIN12=ON
cmake --build "$WORK_DIR/x265-12bit" --parallel "$(sysctl -n hw.logicalcpu)"

mkdir -p "$WORK_DIR/x265-8bit"
cp "$WORK_DIR/x265-10bit/libx265.a" "$WORK_DIR/x265-8bit/libx265_main10.a"
cp "$WORK_DIR/x265-12bit/libx265.a" "$WORK_DIR/x265-8bit/libx265_main12.a"

cmake -S "$X265_SOURCE_DIR/source" -B "$WORK_DIR/x265-8bit" \
  "${X265_COMMON_ARGS[@]}" \
  -DLINKED_10BIT=ON \
  -DLINKED_12BIT=ON \
  -DEXTRA_LINK_FLAGS=-L. \
  '-DEXTRA_LIB=x265_main10.a;x265_main12.a'
cmake --build "$WORK_DIR/x265-8bit" --parallel "$(sysctl -n hw.logicalcpu)"

mv "$WORK_DIR/x265-8bit/libx265.a" "$WORK_DIR/x265-8bit/libx265_main.a"
libtool -static -o "$WORK_DIR/x265-8bit/libx265.a" \
  "$WORK_DIR/x265-8bit/libx265_main.a" \
  "$WORK_DIR/x265-8bit/libx265_main10.a" \
  "$WORK_DIR/x265-8bit/libx265_main12.a"
cmake --install "$WORK_DIR/x265-8bit"

# The subtitle subshell intentionally cannot leak its isolated lookup paths.
# shellcheck disable=SC2031
export PKG_CONFIG_PATH="$X264_PREFIX/lib/pkgconfig:$X265_PREFIX/lib/pkgconfig:$SUBTITLE_PREFIX/lib/pkgconfig"
# shellcheck disable=SC2031
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"

echo "Building FFmpeg $FFMPEG_VERSION..."
cd "$FFMPEG_SOURCE_DIR"
./configure \
  --prefix="$INSTALL_PREFIX" \
  --arch="$ARCHITECTURE" \
  --target-os=darwin \
  --cc=clang \
  --pkg-config-flags=--static \
  --extra-cflags="$TARGET_CFLAGS -I$X264_PREFIX/include -I$X265_PREFIX/include -I$SUBTITLE_PREFIX/include" \
  --extra-ldflags="$TARGET_LDFLAGS -L$X264_PREFIX/lib -L$X265_PREFIX/lib -L$SUBTITLE_PREFIX/lib" \
  --enable-gpl \
  --enable-version3 \
  --enable-libx264 \
  --enable-libx265 \
  --enable-libass \
  --enable-videotoolbox \
  --enable-audiotoolbox \
  --enable-zlib \
  --disable-autodetect \
  --disable-debug \
  --disable-doc \
  --disable-ffplay \
  --disable-network \
  --disable-shared \
  --enable-static

make -j"$(sysctl -n hw.logicalcpu)" ffmpeg ffprobe

cp ffmpeg ffprobe "$OUTPUT_DIR/"
chmod 755 "$OUTPUT_DIR/ffmpeg" "$OUTPUT_DIR/ffprobe"
strip -x "$OUTPUT_DIR/ffmpeg" "$OUTPUT_DIR/ffprobe"

for executable in "$OUTPUT_DIR/ffmpeg" "$OUTPUT_DIR/ffprobe"; do
  unexpected_dependencies="$(otool -L "$executable" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/System/|/usr/lib/)' || true)"
  if [[ -n "$unexpected_dependencies" ]]; then
    echo "Unexpected non-system dependencies in $executable:" >&2
    echo "$unexpected_dependencies" >&2
    exit 1
  fi
done

mach_o_minimum_version() {
  local executable="$1"

  otool -l "$executable" | awk '
    $1 == "cmd" {
      modern = ($2 == "LC_BUILD_VERSION")
      legacy = ($2 == "LC_VERSION_MIN_MACOSX")
      next
    }
    modern && $1 == "minos" {
      print $2
      exit
    }
    legacy && $1 == "version" {
      print $2
      exit
    }
  '
}

for executable in "$OUTPUT_DIR/ffmpeg" "$OUTPUT_DIR/ffprobe"; do
  executable_minimum_version="$(mach_o_minimum_version "$executable")"
  if [[ -z "$executable_minimum_version" ]]; then
    echo "Unable to determine the minimum macOS version for $executable." >&2
    exit 1
  fi
  executable_version_number="$(version_number "$executable_minimum_version")" || exit 1
  if (( executable_version_number > target_version_number )); then
    echo "$executable requires macOS $executable_minimum_version, which exceeds the target $DEPLOYMENT_TARGET." >&2
    exit 1
  fi
  echo "$(basename "$executable") supports macOS $executable_minimum_version or later (target: $DEPLOYMENT_TARGET)."
done

ENCODERS="$("$OUTPUT_DIR/ffmpeg" -hide_banner -encoders 2>&1)"
for encoder in libx264 libx265 prores_ks ffv1 alac mjpeg png exr; do
  if ! grep -q "[[:space:]]${encoder}[[:space:]]" <<<"$ENCODERS"; then
    echo "Required FFmpeg encoder is unavailable: $encoder" >&2
    exit 1
  fi
done

FILTERS="$("$OUTPUT_DIR/ffmpeg" -hide_banner -filters 2>&1)"
for filter_name in transpose trim setpts hflip vflip scale format ass subtitles; do
  if ! grep -q "[[:space:]]${filter_name}[[:space:]]" <<<"$FILTERS"; then
    echo "Required FFmpeg filter is unavailable: $filter_name" >&2
    exit 1
  fi
done

BUILD_CONFIGURATION="$("$OUTPUT_DIR/ffmpeg" -hide_banner -version 2>&1)"
for option in --enable-gpl --enable-version3 --enable-libx264 --enable-libx265 --enable-libass; do
  if ! grep -q -- "$option" <<<"$BUILD_CONFIGURATION"; then
    echo "Required FFmpeg license/build option is missing: $option" >&2
    exit 1
  fi
done

codesign --force --sign - "$OUTPUT_DIR/ffmpeg" "$OUTPUT_DIR/ffprobe"
echo "Media executables are ready in $OUTPUT_DIR"
