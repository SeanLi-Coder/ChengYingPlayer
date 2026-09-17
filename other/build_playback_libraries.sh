#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_ROOT/deps}"
SOURCE_CACHE_DIR="${SOURCE_CACHE_DIR:-$PROJECT_ROOT/deps/sources}"
ARCHITECTURE="${ARCHS:-$(uname -m)}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"

# shellcheck source=other/third_party_sources.sh
source "$SCRIPT_DIR/third_party_sources.sh"
# shellcheck source=other/playback_sources.sh
source "$SCRIPT_DIR/playback_sources.sh"
# shellcheck source=other/playback_patches.sh
source "$SCRIPT_DIR/playback_patches.sh"
# shellcheck source=other/build_subtitle_libraries.sh
source "$SCRIPT_DIR/build_subtitle_libraries.sh"

if [[ "$(uname -s)" != Darwin || "$ARCHITECTURE" != arm64 || "$(uname -m)" != arm64 ]]; then
  echo "The source-built playback release currently requires a native arm64 macOS host." >&2
  exit 2
fi
for command_name in clang clang++ cmake curl make meson ninja otool install_name_tool codesign pkg-config shasum tar patch autoreconf automake glibtoolize; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required playback build command is unavailable: $command_name" >&2
    exit 2
  fi
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chengying-playback-build.XXXXXX")"
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
cleanup() {
  if [[ "${KEEP_PLAYBACK_BUILD:-0}" == 1 ]]; then
    echo "Playback work directory retained at $WORK_DIR"
  elif [[ "$(basename "$WORK_DIR")" == chengying-playback-build.* ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

PREFIX="$WORK_DIR/install"
RECORD_DIR="$WORK_DIR/build-record"
mkdir -p "$PREFIX" "$RECORD_DIR/licenses"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
TARGET_CFLAGS="-arch $ARCHITECTURE -mmacosx-version-min=$DEPLOYMENT_TARGET -fPIC"
TARGET_LDFLAGS="-arch $ARCHITECTURE -mmacosx-version-min=$DEPLOYMENT_TARGET"
# The subtitle function uses its own subshell and cannot modify these values.
# shellcheck disable=SC2031
export CC=clang CXX=clang++
# shellcheck disable=SC2031
export CFLAGS="$TARGET_CFLAGS" CXXFLAGS="$TARGET_CFLAGS"
# shellcheck disable=SC2031
export CPPFLAGS="-I$PREFIX/include" LDFLAGS="$TARGET_LDFLAGS -L$PREFIX/lib"
# shellcheck disable=SC2031
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
# shellcheck disable=SC2031
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
PARALLELISM="$(sysctl -n hw.logicalcpu)"

while IFS=$'\t' read -r name _; do
  archive="$(fetch_playback_source "$name" "$SOURCE_CACHE_DIR")"
  tar -xf "$archive" -C "$WORK_DIR"
done < <(playback_source_records)

apply_playback_patches "$WORK_DIR" "$RECORD_DIR"

echo "Building isolated static subtitle libraries..."
build_subtitle_libraries "$PREFIX"

MESON_COMMON=(--prefix "$PREFIX" --libdir lib --buildtype release --wrap-mode nofallback -Ddefault_library=static)

echo "Building dav1d AV1 decoder..."
meson setup "$WORK_DIR/dav1d-build" "$WORK_DIR/dav1d-$PLAYBACK_DAV1D_VERSION" \
  "${MESON_COMMON[@]}" -Denable_tools=false -Denable_tests=false
meson compile -C "$WORK_DIR/dav1d-build" -j "$PARALLELISM"
meson install -C "$WORK_DIR/dav1d-build"

echo "Building Little CMS color management..."
cd "$WORK_DIR/lcms2-$PLAYBACK_LCMS_VERSION"
./configure --prefix="$PREFIX" --disable-shared --enable-static --without-jpeg --without-tiff
make -j"$PARALLELISM"
make install

echo "Building zimg high-quality software scaling..."
cd "$WORK_DIR/zimg-release-$PLAYBACK_ZIMG_VERSION"
./autogen.sh
./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-testapp
make -j"$PARALLELISM"
make install

echo "Building subtitle encoding detection..."
cmake -S "$WORK_DIR/uchardet-$PLAYBACK_UCHARDET_VERSION" -B "$WORK_DIR/uchardet-build" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_OSX_ARCHITECTURES="$ARCHITECTURE" -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_BINARY=OFF
cmake --build "$WORK_DIR/uchardet-build" --parallel "$PARALLELISM"
cmake --install "$WORK_DIR/uchardet-build"

echo "Building libplacebo color and rendering primitives..."
cp -R "$WORK_DIR/fast_float-$PLAYBACK_FAST_FLOAT_COMMIT/include" \
  "$WORK_DIR/libplacebo-$PLAYBACK_PLACEBO_VERSION/3rdparty/fast_float/"
cp -R "$WORK_DIR/jinja-$PLAYBACK_JINJA_COMMIT/src" \
  "$WORK_DIR/libplacebo-$PLAYBACK_PLACEBO_VERSION/3rdparty/jinja/"
cp -R "$WORK_DIR/markupsafe-$PLAYBACK_MARKUPSAFE_COMMIT/src" \
  "$WORK_DIR/libplacebo-$PLAYBACK_PLACEBO_VERSION/3rdparty/markupsafe/"
cp -R "$WORK_DIR/Vulkan-Headers-$PLAYBACK_VULKAN_HEADERS_COMMIT/include" \
  "$WORK_DIR/libplacebo-$PLAYBACK_PLACEBO_VERSION/3rdparty/Vulkan-Headers/"
# libmpv's embedded OpenGL renderer owns the actual GL context; its libplacebo
# dependency supplies color primitives, not a second Vulkan/Metal renderer.
meson setup "$WORK_DIR/placebo-build" "$WORK_DIR/libplacebo-$PLAYBACK_PLACEBO_VERSION" \
  "${MESON_COMMON[@]}" -Dauto_features=disabled -Ddemos=false -Dtests=false -Dlcms=enabled -Ddovi=enabled
meson compile -C "$WORK_DIR/placebo-build" -j "$PARALLELISM"
meson install -C "$WORK_DIR/placebo-build"

echo "Building FFmpeg $PLAYBACK_FFMPEG_VERSION playback libraries..."
cd "$WORK_DIR/ffmpeg-$PLAYBACK_FFMPEG_VERSION"
# libass exposes iconv during configure probes; also link the system library
# explicitly so FFmpeg's separate avcodec dylib does not lose that dependency.
./configure --prefix="$PREFIX" --arch="$ARCHITECTURE" --target-os=darwin --cc=clang \
  --pkg-config-flags=--static --extra-cflags="$TARGET_CFLAGS -I$PREFIX/include" \
  --extra-ldflags="$TARGET_LDFLAGS -L$PREFIX/lib" \
  --extra-libs=-liconv \
  --enable-gpl --enable-version3 --enable-shared --disable-static --disable-autodetect \
  --enable-libdav1d --enable-libass --enable-libzimg --enable-videotoolbox \
  --enable-audiotoolbox --enable-securetransport --enable-zlib --enable-bzlib --enable-iconv \
  --disable-programs --disable-doc --disable-debug --install-name-dir=@rpath
make -j"$PARALLELISM"
make install
cp config.h config_components.h "$RECORD_DIR/"
cp ffbuild/config.mak "$RECORD_DIR/ffmpeg-config.mak"

echo "Building libmpv $PLAYBACK_MPV_VERSION with native Apple playback..."
# Auto-detection is off so an unrelated Homebrew package cannot silently enter
# the runtime. Built-in scaletempo2 keeps pitch-correct playback speed changes.
PKG_CONFIG="$SCRIPT_DIR/playback_pkg_config.sh" meson setup "$WORK_DIR/mpv-build" "$WORK_DIR/mpv-$PLAYBACK_MPV_VERSION" \
  --prefix "$PREFIX" --libdir lib --buildtype release --wrap-mode nofallback \
  -Dauto_features=disabled -Dprefer_static=false -Dlibmpv=true -Dcplayer=false \
  -Dbuild-date=false -Dgpl=true -Dlua=disabled -Dcocoa=enabled -Dgl-cocoa=enabled -Dgl=enabled -Dplain-gl=enabled \
  -Dswift-build=enabled "-Dswift-flags=-target arm64-apple-macosx$DEPLOYMENT_TARGET" \
  -Dvideotoolbox-gl=enabled -Dcoreaudio=enabled -Dlcms2=enabled -Dzimg=enabled \
  -Duchardet=enabled -Diconv=enabled -Dzlib=enabled -Dlibavdevice=enabled
meson compile -C "$WORK_DIR/mpv-build" -j "$PARALLELISM"
meson install -C "$WORK_DIR/mpv-build"
cp "$WORK_DIR/mpv-build/config.h" "$RECORD_DIR/mpv-config.h"
cp "$WORK_DIR/mpv-build/meson-info/intro-buildoptions.json" "$RECORD_DIR/mpv-buildoptions.json"
cp "$WORK_DIR/placebo-build/meson-info/intro-buildoptions.json" "$RECORD_DIR/libplacebo-buildoptions.json"

mkdir -p "$WORK_DIR/staged/lib" "$WORK_DIR/staged/include"
while IFS= read -r name; do
  cp -L "$PREFIX/lib/$name" "$WORK_DIR/staged/lib/$name"
  install_name_tool -id "@rpath/$name" "$WORK_DIR/staged/lib/$name"
done < <(playback_library_names)
for library in "$WORK_DIR/staged/lib/"*.dylib; do
  while IFS= read -r dependency; do
    case "$dependency" in
      "$PREFIX"/lib/*.dylib)
        install_name_tool -change "$dependency" "@rpath/$(basename "$dependency")" "$library"
        ;;
    esac
  done < <(otool -L "$library" | tail -n +2 | awk '{print $1}')
  while IFS= read -r dependency; do
    case "$dependency" in
      /System/* | /usr/lib/*) ;;
      @rpath/*.dylib)
        if [[ ! -f "$WORK_DIR/staged/lib/${dependency#@rpath/}" ]]; then
          echo "Unbundled playback dependency: $dependency" >&2
          exit 1
        fi
        ;;
      *) echo "Unexpected playback dependency: $dependency" >&2; exit 1 ;;
    esac
  done < <(otool -L "$library" | tail -n +2 | awk '{print $1}')
  lipo "$library" -verify_arch arm64
  while IFS= read -r runtime_path; do
    case "$runtime_path" in
      /usr/lib/swift | @loader_path*) ;;
      *) install_name_tool -delete_rpath "$runtime_path" "$library" ;;
    esac
  done < <(otool -l "$library" | awk '$1 == "cmd" {rpath = ($2 == "LC_RPATH")} rpath && $1 == "path" {print $2}')
  codesign --force --sign - "$library"
done

for directory in mpv libavcodec libavdevice libavfilter libavformat libavutil libpostproc libswresample libswscale; do
  cp -R "$PREFIX/include/$directory" "$WORK_DIR/staged/include/"
done

playback_source_records > "$RECORD_DIR/sources.tsv"
third_party_source_records | awk -F '\t' '$1 ~ /^(freetype|harfbuzz|fribidi|libunibreak|libass)$/' >> "$RECORD_DIR/sources.tsv"
{
  printf 'Architecture: %s\nDeployment target: %s\n' "$ARCHITECTURE" "$DEPLOYMENT_TARGET"
  xcrun clang --version
  printf 'SDK: %s\nmacOS: %s\n' "$(xcrun --show-sdk-version)" "$(sw_vers -productVersion)"
  cmake --version
  meson --version
  ninja --version
} > "$RECORD_DIR/toolchain.txt"
# Configuration output may contain the temporary prefix; retain the flags but
# remove machine-specific build roots before publishing the build record.
for record in "$RECORD_DIR/"*.mak "$RECORD_DIR/"*.json "$RECORD_DIR/"*.h; do
  perl -0pi -e 'BEGIN { $build_root = shift @ARGV; } s/\Q$build_root\E/<BUILD_ROOT>/g' "$WORK_DIR" "$record"
done
(
  cd "$WORK_DIR/staged/lib"
  shasum -a 256 ./*.dylib
) > "$RECORD_DIR/library-sha256.txt"
(
  cd "$WORK_DIR/staged/include"
  find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
) > "$RECORD_DIR/headers-sha256.txt"

# Preserve original notices, including embedded permissively licensed code.
for source_dir in "$WORK_DIR"/mpv-* "$WORK_DIR"/ffmpeg-* "$WORK_DIR"/libplacebo-* \
  "$WORK_DIR"/dav1d-* "$WORK_DIR"/lcms2-* "$WORK_DIR"/zimg-release-* \
  "$WORK_DIR"/fast_float-* "$WORK_DIR"/uchardet-* "$WORK_DIR"/freetype-* \
  "$WORK_DIR"/jinja-* "$WORK_DIR"/markupsafe-* \
  "$WORK_DIR"/Vulkan-Headers-* \
  "$WORK_DIR"/harfbuzz-* "$WORK_DIR"/fribidi-* "$WORK_DIR"/libunibreak-* "$WORK_DIR"/libass-*; do
  [[ -d "$source_dir" && "$source_dir" != *-build ]] || continue
  component="$(basename "$source_dir")"
  while IFS= read -r notice; do
    relative="${notice#"$source_dir"/}"
    mkdir -p "$RECORD_DIR/licenses/$component/$(dirname "$relative")"
    cp "$notice" "$RECORD_DIR/licenses/$component/$relative"
  done < <(find "$source_dir" -type f \( -iname 'COPYING*' -o -iname 'LICENSE*' -o -iname 'LICENCE*' \
    -o -iname 'COPYRIGHT*' -o -iname 'NOTICE*' -o -iname 'AUTHORS*' -o -name 'FTL.TXT' \))
done

# No existing headers or libraries are touched until the complete build and
# dependency-closure checks succeed. Unrelated helper assets remain intact.
mkdir -p "$OUTPUT_DIR/lib" "$OUTPUT_DIR/include" "$OUTPUT_DIR/playback-build-record"
cp -R "$WORK_DIR/staged/lib/." "$OUTPUT_DIR/lib/"
cp -R "$WORK_DIR/staged/include/." "$OUTPUT_DIR/include/"
cp -R "$RECORD_DIR/." "$OUTPUT_DIR/playback-build-record/"
echo "Source-built arm64 playback libraries are ready in $OUTPUT_DIR"
