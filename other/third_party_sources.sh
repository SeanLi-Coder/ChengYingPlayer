#!/bin/bash

# Exact media-tool source inputs and matching source distributions for the
# helper runtime/build tools. Python build wheels are pinned separately in
# Tools/VideoToolsHelper/requirements-build.txt.

# shellcheck source=other/playback_sources.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/playback_sources.sh"

JUST_COMMIT="1824bf84cf52d11d69ae20cfb89f0ce5bffa5650"
PROMISEKIT_COMMIT="8a98e31a47854d3180882c8068cc4d9381bf382d"
GRMUSTACHE_COMMIT="6e9dcfb807959e19f2915be1928aeccf01babba5"
SPARKLE_COMMIT="eef1a539a373c1f1a320624b1130fc5de7b2e100"

FFMPEG_VERSION="9.0.1"
FFMPEG_SOURCE_FILE="ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_SOURCE_URL="https://ffmpeg.org/releases/${FFMPEG_SOURCE_FILE}"
FFMPEG_SOURCE_SHA256="cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635"

LIBWEBP_VERSION="1.6.0"
LIBWEBP_SOURCE_FILE="libwebp-${LIBWEBP_VERSION}.tar.gz"
LIBWEBP_SOURCE_URL="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/${LIBWEBP_SOURCE_FILE}"
LIBWEBP_SOURCE_SHA256="e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564"

X264_VERSION="r3222"
X264_COMMIT="b35605ace3ddf7c1a5d67a2eb553f034aef41d55"
X264_SOURCE_FILE="x264-${X264_COMMIT}.tar.gz"
X264_SOURCE_URL="https://code.videolan.org/videolan/x264/-/archive/${X264_COMMIT}/${X264_SOURCE_FILE}"
X264_SOURCE_SHA256="cd71a7515b0e9a012e1ac9b1f8415bebcaf6fc97d4db32286642ac4c0fbe24f9"

X265_VERSION="4.3"
X265_SOURCE_FILE="x265_${X265_VERSION}.tar.gz"
X265_SOURCE_URL="https://github.com/Multicorewareinc/x265/releases/download/${X265_VERSION}/${X265_SOURCE_FILE}"
X265_SOURCE_SHA256="83c53e4c8bbb8f1e33ed59e10a7d621d1d7801ca853910c3eb41f038b8ffb121"

FREETYPE_VERSION="2.14.3"
FREETYPE_SOURCE_FILE="freetype-${FREETYPE_VERSION}.tar.xz"
FREETYPE_SOURCE_URL="https://download.savannah.gnu.org/releases/freetype/${FREETYPE_SOURCE_FILE}"
FREETYPE_SOURCE_SHA256="36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f"

HARFBUZZ_VERSION="14.4.0"
HARFBUZZ_SOURCE_FILE="harfbuzz-${HARFBUZZ_VERSION}.tar.xz"
HARFBUZZ_SOURCE_URL="https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/${HARFBUZZ_SOURCE_FILE}"
HARFBUZZ_SOURCE_SHA256="2357ed966c6ced7bfa720b0640c0231065af01158fbea215093ffa15aed44371"

FRIBIDI_VERSION="1.0.16"
FRIBIDI_SOURCE_FILE="fribidi-${FRIBIDI_VERSION}.tar.xz"
FRIBIDI_SOURCE_URL="https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VERSION}/${FRIBIDI_SOURCE_FILE}"
FRIBIDI_SOURCE_SHA256="1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c"

UNIBREAK_VERSION="8.0"
UNIBREAK_SOURCE_FILE="libunibreak-${UNIBREAK_VERSION}.tar.gz"
UNIBREAK_SOURCE_URL="https://github.com/adah1972/libunibreak/releases/download/libunibreak_8_0/${UNIBREAK_SOURCE_FILE}"
UNIBREAK_SOURCE_SHA256="9c4fad6e517338a098373acc9f35579ae2c325e6446666fb9ac2666ba15ceba4"

LIBASS_VERSION="0.17.5"
LIBASS_SOURCE_FILE="libass-${LIBASS_VERSION}.tar.xz"
LIBASS_SOURCE_URL="https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/${LIBASS_SOURCE_FILE}"
LIBASS_SOURCE_SHA256="2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc"

PYTHON_VERSION="3.13.2"
PYTHON_SOURCE_FILE="Python-${PYTHON_VERSION}.tgz"
PYTHON_SOURCE_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/${PYTHON_SOURCE_FILE}"
PYTHON_SOURCE_SHA256="b8d79530e3b7c96a5cb2d40d431ddb512af4a563e863728d8713039aa50203f9"

PYINSTALLER_VERSION="6.22.2"
PYINSTALLER_SOURCE_FILE="pyinstaller-${PYINSTALLER_VERSION}.tar.gz"
PYINSTALLER_SOURCE_URL="https://files.pythonhosted.org/packages/source/p/pyinstaller/${PYINSTALLER_SOURCE_FILE}"
PYINSTALLER_SOURCE_SHA256="89b65a3ad07d9dd5832253e37bc45f31872d10d7f9d5c9fd0fdd6088a83829dd"

ALTGRAPH_VERSION="0.17.5"
ALTGRAPH_SOURCE_FILE="altgraph-${ALTGRAPH_VERSION}.tar.gz"
ALTGRAPH_SOURCE_URL="https://files.pythonhosted.org/packages/7e/f8/97fdf103f38fed6792a1601dbc16cc8aac56e7459a9fff08c812d8ae177a/${ALTGRAPH_SOURCE_FILE}"
ALTGRAPH_SOURCE_SHA256="c87b395dd12fabde9c99573a9749d67da8d29ef9de0125c7f536699b4a9bc9e7"

MACHOLIB_VERSION="1.16.4"
MACHOLIB_SOURCE_FILE="macholib-${MACHOLIB_VERSION}.tar.gz"
MACHOLIB_SOURCE_URL="https://files.pythonhosted.org/packages/10/2f/97589876ea967487978071c9042518d28b958d87b17dceb7cdc1d881f963/${MACHOLIB_SOURCE_FILE}"
MACHOLIB_SOURCE_SHA256="f408c93ab2e995cd2c46e34fe328b130404be143469e41bc366c807448979362"

PACKAGING_VERSION="26.3"
PACKAGING_SOURCE_FILE="packaging-${PACKAGING_VERSION}.tar.gz"
PACKAGING_SOURCE_URL="https://files.pythonhosted.org/packages/7d/fa/3944b40b07da9ce895c0e6303a5ab7d53da063554f534556b134a54d6093/${PACKAGING_SOURCE_FILE}"
PACKAGING_SOURCE_SHA256="94edc256424af38762eb31306eed28beb9f0efc50a8837492c9d6fd6004aed79"

PYINSTALLER_HOOKS_VERSION="2026.7"
PYINSTALLER_HOOKS_SOURCE_FILE="pyinstaller_hooks_contrib-${PYINSTALLER_HOOKS_VERSION}.tar.gz"
PYINSTALLER_HOOKS_SOURCE_URL="https://files.pythonhosted.org/packages/26/60/d881fa1ba8c160c18d8e6f782bb16ec4640c08bc08fc50f704c368ad4f9e/${PYINSTALLER_HOOKS_SOURCE_FILE}"
PYINSTALLER_HOOKS_SOURCE_SHA256="5fbcaacb22c4f4aac869a127dce283f67a4b4cfcc37d496f2446603e6d68aefa"

SETUPTOOLS_VERSION="84.0.0"
SETUPTOOLS_SOURCE_FILE="setuptools-${SETUPTOOLS_VERSION}.tar.gz"
SETUPTOOLS_SOURCE_URL="https://files.pythonhosted.org/packages/6d/44/f5da03a8ef95d369145c5bb53050e7877c9f3d312e128605fd9504829143/${SETUPTOOLS_SOURCE_FILE}"
SETUPTOOLS_SOURCE_SHA256="f4695c21257f0d9b537ec2692c941d02ee143b7cc1276941349a546573b2ef73"

third_party_source_records() {
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "ffmpeg" "$FFMPEG_VERSION" "$FFMPEG_SOURCE_FILE" "$FFMPEG_SOURCE_URL" "$FFMPEG_SOURCE_SHA256" \
    "libwebp" "$LIBWEBP_VERSION" "$LIBWEBP_SOURCE_FILE" "$LIBWEBP_SOURCE_URL" "$LIBWEBP_SOURCE_SHA256" \
    "x264" "$X264_VERSION-$X264_COMMIT" "$X264_SOURCE_FILE" "$X264_SOURCE_URL" "$X264_SOURCE_SHA256" \
    "x265" "$X265_VERSION" "$X265_SOURCE_FILE" "$X265_SOURCE_URL" "$X265_SOURCE_SHA256" \
    "freetype" "$FREETYPE_VERSION" "$FREETYPE_SOURCE_FILE" "$FREETYPE_SOURCE_URL" "$FREETYPE_SOURCE_SHA256" \
    "harfbuzz" "$HARFBUZZ_VERSION" "$HARFBUZZ_SOURCE_FILE" "$HARFBUZZ_SOURCE_URL" "$HARFBUZZ_SOURCE_SHA256" \
    "fribidi" "$FRIBIDI_VERSION" "$FRIBIDI_SOURCE_FILE" "$FRIBIDI_SOURCE_URL" "$FRIBIDI_SOURCE_SHA256" \
    "libunibreak" "$UNIBREAK_VERSION" "$UNIBREAK_SOURCE_FILE" "$UNIBREAK_SOURCE_URL" "$UNIBREAK_SOURCE_SHA256" \
    "libass" "$LIBASS_VERSION" "$LIBASS_SOURCE_FILE" "$LIBASS_SOURCE_URL" "$LIBASS_SOURCE_SHA256" \
    "cpython" "$PYTHON_VERSION" "$PYTHON_SOURCE_FILE" "$PYTHON_SOURCE_URL" "$PYTHON_SOURCE_SHA256" \
    "pyinstaller" "$PYINSTALLER_VERSION" "$PYINSTALLER_SOURCE_FILE" "$PYINSTALLER_SOURCE_URL" "$PYINSTALLER_SOURCE_SHA256" \
    "altgraph" "$ALTGRAPH_VERSION" "$ALTGRAPH_SOURCE_FILE" "$ALTGRAPH_SOURCE_URL" "$ALTGRAPH_SOURCE_SHA256" \
    "macholib" "$MACHOLIB_VERSION" "$MACHOLIB_SOURCE_FILE" "$MACHOLIB_SOURCE_URL" "$MACHOLIB_SOURCE_SHA256" \
    "packaging" "$PACKAGING_VERSION" "$PACKAGING_SOURCE_FILE" "$PACKAGING_SOURCE_URL" "$PACKAGING_SOURCE_SHA256" \
    "pyinstaller-hooks-contrib" "$PYINSTALLER_HOOKS_VERSION" "$PYINSTALLER_HOOKS_SOURCE_FILE" "$PYINSTALLER_HOOKS_SOURCE_URL" "$PYINSTALLER_HOOKS_SOURCE_SHA256" \
    "setuptools" "$SETUPTOOLS_VERSION" "$SETUPTOOLS_SOURCE_FILE" "$SETUPTOOLS_SOURCE_URL" "$SETUPTOOLS_SOURCE_SHA256" \
    "just" "$JUST_COMMIT" "Just-$JUST_COMMIT.tar.gz" "https://github.com/dduan/Just/archive/$JUST_COMMIT.tar.gz" \
    "8e3f95382267ba1e01ddd3912a7102395f90018f6df2f1bf54a22984d5dd3451" \
    "promisekit" "$PROMISEKIT_COMMIT" "PromiseKit-$PROMISEKIT_COMMIT.tar.gz" "https://github.com/mxcl/PromiseKit/archive/$PROMISEKIT_COMMIT.tar.gz" \
    "85e1cfef1432e4d25336a88b75cfe3f5ec3b346b2e4b7713690a835ef7f3aead" \
    "grmustache" "$GRMUSTACHE_COMMIT" "GRMustache-$GRMUSTACHE_COMMIT.tar.gz" "https://github.com/groue/GRMustache.swift/archive/$GRMUSTACHE_COMMIT.tar.gz" \
    "382f070dd39429ff4c165060ce6975cd7e1ec506b978c3ad66e9127627538e47" \
    "sparkle" "$SPARKLE_COMMIT" "Sparkle-$SPARKLE_COMMIT.tar.gz" "https://github.com/sparkle-project/Sparkle/archive/$SPARKLE_COMMIT.tar.gz" \
    "fd2a5de329be3619111f9a73a1adeac9725a92292f0431c93679e5e2b0d48a04"
  playback_source_records
}

fetch_verified_source() {
  local component="$1"
  local destination_dir="$2"
  if [[ "$component" == dav1d ]]; then
    # Source packaging must use the same pinned download and verification policy.
    fetch_playback_source "$component" "$destination_dir"
    return $?
  fi
  local record_name=""
  local version=""
  local filename=""
  local url=""
  local expected_sha256=""
  local destination=""
  local partial=""
  local actual_sha256=""

  while IFS=$'\t' read -r record_name version filename url expected_sha256; do
    if [[ "$record_name" == "$component" ]]; then
      break
    fi
  done < <(third_party_source_records)

  if [[ "$record_name" != "$component" || -z "$filename" ]]; then
    echo "Unknown third-party source component: $component" >&2
    return 2
  fi

  mkdir -p "$destination_dir"
  destination="$destination_dir/$filename"
  partial="$destination.partial-$$"

  if [[ -f "$destination" ]]; then
    actual_sha256="$(shasum -a 256 "$destination" | awk '{print $1}')"
    if [[ "$actual_sha256" == "$expected_sha256" ]]; then
      printf '%s\n' "$destination"
      return 0
    fi
    echo "Removing invalid cached source archive: $destination" >&2
    rm -f "$destination"
  fi

  echo "Downloading $record_name $version source..." >&2
  rm -f "$partial"
  curl --fail --location --retry 3 --retry-all-errors \
    "$url" \
    --output "$partial"

  actual_sha256="$(shasum -a 256 "$partial" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "$record_name source checksum mismatch." >&2
    echo "Expected: $expected_sha256" >&2
    echo "Actual:   $actual_sha256" >&2
    rm -f "$partial"
    return 1
  fi

  mv "$partial" "$destination"
  printf '%s\n' "$destination"
}

write_third_party_source_manifest() {
  local destination="$1"
  local record_name=""
  local version=""
  local filename=""
  local url=""
  local expected_sha256=""

  {
    printf '%s\n' "ChengYingPlayer verified third-party source materials"
    printf '%s\n' ""
    printf '%s\n' "SHA256  FILE  COMPONENT  VERSION  SOURCE_URL"
    while IFS=$'\t' read -r record_name version filename url expected_sha256; do
      printf '%s  %s  %s  %s  %s\n' \
        "$expected_sha256" "$filename" "$record_name" "$version" "$url"
    done < <(third_party_source_records)
    "${HELPER_PYTHON:-python3}" "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Tools/DownloaderHelper/source_materials.py" manifest |
      awk '{printf "%s  download-runtime/%s  %s  %s  %s\n", $1, $2, $3, $4, $5}'
  } > "$destination"
}
