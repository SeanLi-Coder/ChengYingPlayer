#!/bin/bash

# Sourced by build_media_binaries.sh after its source locks and target settings.
# Keep all non-system dependencies static and isolated from Homebrew libraries.
build_subtitle_libraries() (
  set -euo pipefail
  local prefix="$1"
  local component archive
  for component in freetype harfbuzz fribidi libunibreak libass; do
    archive="$(fetch_verified_source "$component" "$SOURCE_CACHE_DIR")"
    tar -xf "$archive" -C "$WORK_DIR"
  done

  export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
  export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
  export CC=clang CXX=clang++
  export CFLAGS="$TARGET_CFLAGS" CXXFLAGS="$TARGET_CFLAGS"
  export CPPFLAGS="-I$prefix/include" LDFLAGS="$TARGET_LDFLAGS -L$prefix/lib"
  local parallelism
  parallelism="$(sysctl -n hw.logicalcpu)"
  local common_args=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$prefix"
    -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_OSX_ARCHITECTURES="$ARCHITECTURE"
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    -DCMAKE_PREFIX_PATH="$prefix"
    -DBUILD_SHARED_LIBS=OFF
  )

  cmake -S "$WORK_DIR/freetype-$FREETYPE_VERSION" -B "$WORK_DIR/freetype-build" \
    "${common_args[@]}" -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON \
    -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
  cmake --build "$WORK_DIR/freetype-build" --parallel "$parallelism"
  cmake --install "$WORK_DIR/freetype-build"

  cmake -S "$WORK_DIR/harfbuzz-$HARFBUZZ_VERSION" -B "$WORK_DIR/harfbuzz-build" \
    "${common_args[@]}" -DHB_HAVE_FREETYPE=ON -DHB_HAVE_CORETEXT=ON \
    -DHB_HAVE_GLIB=OFF -DHB_HAVE_ICU=OFF -DHB_HAVE_CAIRO=OFF -DHB_HAVE_GRAPHITE2=OFF \
    -DHB_BUILD_UTILS=OFF -DHB_BUILD_SUBSET=OFF -DHB_BUILD_RASTER=OFF \
    -DHB_BUILD_VECTOR=OFF -DHB_BUILD_GPU=OFF -DHB_BUILD_GPU_DEMO=OFF
  cmake --build "$WORK_DIR/harfbuzz-build" --parallel "$parallelism"
  cmake --install "$WORK_DIR/harfbuzz-build"

  cd "$WORK_DIR/fribidi-$FRIBIDI_VERSION"
  ./configure --prefix="$prefix" --disable-shared --enable-static --disable-docs
  make -j"$parallelism"
  make install

  cd "$WORK_DIR/libunibreak-$UNIBREAK_VERSION"
  ./configure --prefix="$prefix" --disable-shared --enable-static
  make -j"$parallelism"
  make install

  cd "$WORK_DIR/libass-$LIBASS_VERSION"
  ./configure --prefix="$prefix" --disable-shared --enable-static \
    --disable-fontconfig --enable-coretext --enable-libunibreak
  make -j"$parallelism"
  make install
)
