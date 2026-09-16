#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_ROOT/deps/executable}"
SOURCE_CACHE_DIR="${SOURCE_CACHE_DIR:-$PROJECT_ROOT/deps/sources}"
ARCHITECTURE="${ARCHS:-$(uname -m)}"
# shellcheck source=other/third_party_sources.sh
source "$SCRIPT_DIR/third_party_sources.sh"

case "$ARCHITECTURE" in
  arm64) DEPLOYMENT_TARGET="12.0" ;;
  x86_64) DEPLOYMENT_TARGET="10.15" ;;
  *) echo "Unsupported image codec architecture: $ARCHITECTURE" >&2; exit 2 ;;
esac
for command_name in clang cmake curl otool shasum tar; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Required image codec build command is unavailable: $command_name" >&2
    exit 2
  }
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chengying-image-codec.XXXXXX")"
cleanup() {
  if [[ "$WORK_DIR" == "${TMPDIR:-/tmp}"/chengying-image-codec.* ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT
ARCHIVE="$(fetch_verified_source libwebp "$SOURCE_CACHE_DIR")"
tar -xf "$ARCHIVE" -C "$WORK_DIR"
SOURCE_DIR="$WORK_DIR/libwebp-$LIBWEBP_VERSION"
BUILD_DIR="$WORK_DIR/build"
PREFIX="$WORK_DIR/install"

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_OSX_ARCHITECTURES="$ARCHITECTURE" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DBUILD_SHARED_LIBS=OFF -DWEBP_LINK_STATIC=ON \
  -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF \
  -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
  -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
  -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_LIBWEBPMUX=ON \
  -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF \
  -DWEBP_USE_THREAD=OFF -DWEBP_NEAR_LOSSLESS=OFF
cmake --build "$BUILD_DIR" --parallel "$(sysctl -n hw.logicalcpu)"
cmake --install "$BUILD_DIR"

EXECUTABLE="$WORK_DIR/chengying-image-codec"
clang -std=c11 -O2 -Wall -Wextra -Werror \
  -arch "$ARCHITECTURE" -mmacosx-version-min="$DEPLOYMENT_TARGET" \
  -I "$PREFIX/include" "$PROJECT_ROOT/Tools/ImageCodecHelper/codec.c" \
  "$PREFIX/lib/libwebpmux.a" "$PREFIX/lib/libwebp.a" "$PREFIX/lib/libsharpyuv.a" \
  -o "$EXECUTABLE"
unexpected_dependencies="$(otool -L "$EXECUTABLE" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/System/|/usr/lib/)' || true)"
if [[ -n "$unexpected_dependencies" ]]; then
  echo "Image codec contains non-system dynamic dependencies." >&2
  echo "$unexpected_dependencies" >&2
  exit 1
fi
mkdir -p "$OUTPUT_DIR"
install -m 755 "$EXECUTABLE" "$OUTPUT_DIR/chengying-image-codec"
"$OUTPUT_DIR/chengying-image-codec" --version
echo "Source-built image codec is ready. The source-only release gate remains in force."
