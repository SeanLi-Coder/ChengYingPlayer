#!/bin/bash

# Playback stays on the project's public libmpv 2 / FFmpeg 61 ABI. These inputs
# are independent of the FFmpeg CLI used by the editing and download helpers.
PLAYBACK_FFMPEG_VERSION="7.1.5"
PLAYBACK_MPV_VERSION="0.38.0"
PLAYBACK_PLACEBO_VERSION="6.338.2"
PLAYBACK_DAV1D_VERSION="1.5.3"
PLAYBACK_LCMS_VERSION="2.16"
PLAYBACK_ZIMG_VERSION="3.0.5"
PLAYBACK_UCHARDET_VERSION="0.0.8"
PLAYBACK_FAST_FLOAT_COMMIT="2b2395f9ac836ffca6404424bcc252bff7aa80e4"
PLAYBACK_JINJA_COMMIT="b08cd4bc64bb980df86ed2876978ae5735572280"
PLAYBACK_MARKUPSAFE_COMMIT="c0254f0cfe51720ecc9e72e8896022af29af5b44"
PLAYBACK_VULKAN_HEADERS_COMMIT="d732b2de303ce505169011d438178191136bfb00"

# Same five-column interface as third_party_source_records().
playback_source_records() {
  printf '%s\t%s\t%s\t%s\t%s\n' \
    playback-ffmpeg "$PLAYBACK_FFMPEG_VERSION" ffmpeg-7.1.5.tar.xz \
    https://ffmpeg.org/releases/ffmpeg-7.1.5.tar.xz \
    de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f \
    mpv "$PLAYBACK_MPV_VERSION" mpv-0.38.0.tar.gz \
    https://github.com/mpv-player/mpv/archive/refs/tags/v0.38.0.tar.gz \
    86d9ef40b6058732f67b46d0bbda24a074fae860b3eaae05bab3145041303066 \
    libplacebo "$PLAYBACK_PLACEBO_VERSION" libplacebo-v6.338.2.tar.gz \
    https://github.com/haasn/libplacebo/archive/refs/tags/v6.338.2.tar.gz \
    2f1e624e09d72a8c9db70f910f7560e764a1c126dae42acc5b3bcef836a7aec6 \
    dav1d "$PLAYBACK_DAV1D_VERSION" dav1d-1.5.3.tar.xz \
    https://downloads.videolan.org/pub/videolan/dav1d/1.5.3/dav1d-1.5.3.tar.xz \
    732010aa5ef461fa93355ed2c6c5fedb48ddc4b74e697eaabe8907eaeb943011 \
    lcms2 "$PLAYBACK_LCMS_VERSION" lcms2-2.16.tar.gz \
    https://github.com/mm2/Little-CMS/releases/download/lcms2.16/lcms2-2.16.tar.gz \
    d873d34ad8b9b4cea010631f1a6228d2087475e4dc5e763eb81acc23d9d45a51 \
    zimg "$PLAYBACK_ZIMG_VERSION" zimg-3.0.5.tar.gz \
    https://github.com/sekrit-twc/zimg/archive/refs/tags/release-3.0.5.tar.gz \
    a9a0226bf85e0d83c41a8ebe4e3e690e1348682f6a2a7838f1b8cbff1b799bcf \
    fast-float "$PLAYBACK_FAST_FLOAT_COMMIT" fast_float-2b2395f9ac836ffca6404424bcc252bff7aa80e4.tar.gz \
    https://github.com/fastfloat/fast_float/archive/2b2395f9ac836ffca6404424bcc252bff7aa80e4.tar.gz \
    230d20e4e4ac1f6a9df92c4d746c6ec536cdb0c085bc8635d4b88cead5dc22cb \
    uchardet "$PLAYBACK_UCHARDET_VERSION" uchardet-0.0.8.tar.xz \
    https://www.freedesktop.org/software/uchardet/releases/uchardet-0.0.8.tar.xz \
    e97a60cfc00a1c147a674b097bb1422abd9fa78a2d9ce3f3fdcc2e78a34ac5f0 \
    playback-jinja "$PLAYBACK_JINJA_COMMIT" jinja-b08cd4bc64bb980df86ed2876978ae5735572280.tar.gz \
    https://github.com/pallets/jinja/archive/b08cd4bc64bb980df86ed2876978ae5735572280.tar.gz \
    9a20bab550a760ccb9b38a45d4fe76be92649206ee04633c646d0935a1872b0e \
    playback-markupsafe "$PLAYBACK_MARKUPSAFE_COMMIT" markupsafe-c0254f0cfe51720ecc9e72e8896022af29af5b44.tar.gz \
    https://github.com/pallets/markupsafe/archive/c0254f0cfe51720ecc9e72e8896022af29af5b44.tar.gz \
    1826c5d89cc1aa0b3088f538726d339e0c5cd69fbe03f7b8f9a3f880474d1120 \
    playback-vulkan-headers "$PLAYBACK_VULKAN_HEADERS_COMMIT" Vulkan-Headers-d732b2de303ce505169011d438178191136bfb00.tar.gz \
    https://github.com/KhronosGroup/Vulkan-Headers/archive/d732b2de303ce505169011d438178191136bfb00.tar.gz \
    570f9ae1e65466dbaf5fcab667abd079dd0a61c4ab86cf535efd492bf70a5b74
}

fetch_playback_source() (
  set -euo pipefail
  component="$1"
  destination_dir="$2"
  while IFS=$'\t' read -r name version filename url expected; do
    [[ "$component" == "$name" ]] || continue
    case "$url" in
      https://*) ;;
      *) echo "Playback source URL must use HTTPS: $name." >&2; exit 2 ;;
    esac
    mkdir -p "$destination_dir" || exit "$?"
    destination="$destination_dir/$filename"
    if [[ -f "$destination" ]]; then
      actual="$(shasum -a 256 "$destination" | awk '{print $1}')" || exit "$?"
      if [[ "$actual" == "$expected" ]]; then
        printf '%s\n' "$destination"
        exit 0
      fi
    fi
    partial="$(mktemp "$destination.partial.XXXXXX")" || exit "$?"
    trap 'rm -f "$partial"' EXIT
    fallback=""
    curl_options=(--fail --location --proto '=https' --proto-redir '=https')
    if [[ "$name" == dav1d && "$version" == 1.5.3 && \
          "$filename" == dav1d-1.5.3.tar.xz && \
          "$url" == https://downloads.videolan.org/pub/videolan/dav1d/1.5.3/dav1d-1.5.3.tar.xz ]]; then
      # This mirror was verified byte-for-byte against the pinned source digest.
      fallback="https://sources.buildroot.net/dav1d/dav1d-1.5.3.tar.xz"
      curl_options+=(--connect-timeout 15 --max-time 120 --retry 0)
    else
      curl_options+=(--retry 3 --retry-all-errors)
    fi
    echo "Downloading $name $version source..." >&2
    if curl "${curl_options[@]}" "$url" --output "$partial"; then
      :
    else
      download_status=$?
      case "$download_status" in
        6|7|28)
          [[ -n "$fallback" ]] || exit "$download_status"
          echo "Primary $name source is unreachable; trying the verified HTTPS mirror..." >&2
          : > "$partial" || exit "$?"
          curl "${curl_options[@]}" "$fallback" --output "$partial" || exit "$?"
          ;;
        *) exit "$download_status" ;;
      esac
    fi
    actual="$(shasum -a 256 "$partial" | awk '{print $1}')" || exit "$?"
    if [[ "$actual" != "$expected" ]]; then
      echo "Playback source checksum mismatch: $name (expected $expected, got $actual)." >&2
      exit 1
    fi
    mv "$partial" "$destination" || exit "$?"
    printf '%s\n' "$destination"
    exit 0
  done < <(playback_source_records)
  echo "Unknown playback source component: $component" >&2
  exit 2
)

playback_library_names() {
  printf '%s\n' libmpv.2.dylib libavcodec.61.dylib libavdevice.61.dylib \
    libavfilter.10.dylib libavformat.61.dylib libavutil.59.dylib \
    libpostproc.58.dylib libswresample.5.dylib libswscale.8.dylib
}
