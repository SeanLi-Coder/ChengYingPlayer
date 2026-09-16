#!/bin/bash

set -euo pipefail

# universal | arm64 | x86_64
ARCH="universal"
# Plugin releases are mutable and are not required to build the application.
# Keep them opt-in so the default dependency preparation is reproducible.
SKIP_PLUGINS=true

# Keep playback libraries and headers on the same ABI as the IINA v1.4.4
# source baseline. The unversioned iina.io/dylibs endpoint tracks newer IINA
# builds and is not compatible with the headers and Xcode references here.
IINA_RELEASE_VERSION="v1.4.4"
IINA_RELEASE_DMG="IINA.v1.4.4.dmg"
IINA_RELEASE_DMG_URL="https://github.com/iina/iina/releases/download/${IINA_RELEASE_VERSION}/${IINA_RELEASE_DMG}"
IINA_RELEASE_DMG_SHA256="dd0fc0bd4b37fb57a1c8d30d6e3201b3a64bafd29959fe56953964613237beb1"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

printUsageHelp() {
  echo
  echo -e "${BLUE}Usage:${NC}"
  echo -e "    ${GREEN}$0 [-h|--help]:${NC}           Displays this help message"
  echo -e "    ${GREEN}$0 [--arch] <ARCH>:${NC}       Validate the release libraries for: universal | arm64 | x86_64"
  echo -e "    ${GREEN}$0 [--download-plugins]:${NC}  Also download the latest official plugins (not reproducible)"
  echo -e "    ${GREEN}$0 [--skip-plugins]:${NC}      Do not download plugins (default; retained for compatibility)"
  echo
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    printUsageHelp
    exit 0
    ;;
  --arch)
    if [[ $# -lt 2 || -z "$2" ]]; then
      echo -e "${RED}You need to specify an architecture when using --arch${NC}"
      printUsageHelp
      exit 1
    fi
    ARCH=$2
    shift 2
    ;;
  --arch=*)
    ARCH=${1#*=}
    shift
    ;;
  --skip-plugins)
    SKIP_PLUGINS=true
    shift
    ;;
  --download-plugins)
    SKIP_PLUGINS=false
    shift
    ;;
  *)
    echo -e "${RED}Unknown option: $1${NC}" >&2
    printUsageHelp
    exit 1
    ;;
  esac
done

case $ARCH in
universal | arm64 | x86_64)
  ;;
*)
  echo -e "${RED}Invalid architecture: $ARCH${NC}"
  printUsageHelp
  exit 1
  ;;
esac

SCRIPT_PATH=$(cd "$(dirname "$0")" && pwd)
ROOT_PATH=$(cd "$SCRIPT_PATH/.." && pwd)

if [[ ! -d "$ROOT_PATH/iina.xcodeproj" || ! -d "$ROOT_PATH/iina" ]]; then
  echo -e "${RED}Unable to find the project root containing iina.xcodeproj.${NC}" >&2
  exit 1
fi

DEPS_PATH="$ROOT_PATH/deps"
LIB_PATH="$DEPS_PATH/lib"
EXEC_PATH="$DEPS_PATH/executable"
PLUGIN_PATH="$DEPS_PATH/plugins"
YT_DLP_PATH="$EXEC_PATH/youtube-dl"
SOURCE_CACHE_PATH="$DEPS_PATH/sources"
DMG_PATH="$SOURCE_CACHE_PATH/$IINA_RELEASE_DMG"
DMG_PARTIAL_PATH="${DMG_PATH}.partial-$$"
WORK_PATH=$(mktemp -d "${TMPDIR:-/tmp}/chengying-playback-libs.XXXXXX")
MOUNT_PATH="$WORK_PATH/mount"
STAGED_LIB_PATH="$WORK_PATH/lib"
STAGED_YT_DLP_PATH="$WORK_PATH/youtube-dl"
REQUIRED_LIBRARIES_PATH="$WORK_PATH/required-dylibs.txt"
DMG_MOUNTED=false

cleanup() {
  if [[ "$DMG_MOUNTED" == true ]]; then
    hdiutil detach "$MOUNT_PATH" -quiet >/dev/null 2>&1 || true
  fi
  rm -f "$DMG_PARTIAL_PATH"
  if [[ -n "${WORK_PATH:-}" && "$WORK_PATH" == "${TMPDIR:-/tmp}"/chengying-playback-libs.* ]]; then
    rm -rf "$WORK_PATH"
  fi
}
trap cleanup EXIT

for command_name in curl hdiutil lipo shasum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo -e "${RED}Required command is unavailable: ${command_name}${NC}" >&2
    exit 1
  fi
done

mkdir -p "$SOURCE_CACHE_PATH"

if [[ -f "$DMG_PATH" ]]; then
  actual_sha256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
  if [[ "$actual_sha256" != "$IINA_RELEASE_DMG_SHA256" ]]; then
    echo -e "${YELLOW}Removing an invalid cached ${IINA_RELEASE_DMG}.${NC}"
    rm -f "$DMG_PATH"
  fi
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo -e "${YELLOW}Downloading pinned playback libraries from ${IINA_RELEASE_VERSION}...${NC}"
  curl --fail --location --retry 3 --retry-all-errors \
    "$IINA_RELEASE_DMG_URL" \
    --output "$DMG_PARTIAL_PATH"

  actual_sha256=$(shasum -a 256 "$DMG_PARTIAL_PATH" | awk '{print $1}')
  if [[ "$actual_sha256" != "$IINA_RELEASE_DMG_SHA256" ]]; then
    echo -e "${RED}${IINA_RELEASE_DMG} checksum mismatch.${NC}" >&2
    echo "Expected: $IINA_RELEASE_DMG_SHA256" >&2
    echo "Actual:   $actual_sha256" >&2
    exit 1
  fi
  mv "$DMG_PARTIAL_PATH" "$DMG_PATH"
else
  echo -e "${GREEN}Using the verified cached ${IINA_RELEASE_DMG}.${NC}"
fi

mkdir -p "$MOUNT_PATH" "$STAGED_LIB_PATH"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_PATH" -quiet "$DMG_PATH"
DMG_MOUNTED=true

RELEASE_APP_PATH="$MOUNT_PATH/IINA.app"
RELEASE_FRAMEWORKS_PATH="$RELEASE_APP_PATH/Contents/Frameworks"
RELEASE_YT_DLP_PATH="$RELEASE_APP_PATH/Contents/MacOS/youtube-dl"

if [[ ! -d "$RELEASE_FRAMEWORKS_PATH" || ! -f "$RELEASE_YT_DLP_PATH" ]]; then
  echo -e "${RED}The verified release image does not contain the expected playback assets.${NC}" >&2
  exit 1
fi

LC_ALL=C grep -Eo 'lib[^ /;"]+\.dylib' "$ROOT_PATH/iina.xcodeproj/project.pbxproj" \
  | LC_ALL=C sort -u > "$REQUIRED_LIBRARIES_PATH"

if [[ ! -s "$REQUIRED_LIBRARIES_PATH" ]]; then
  echo -e "${RED}Unable to determine the playback libraries referenced by the Xcode project.${NC}" >&2
  exit 1
fi

while IFS= read -r required_library; do
  if [[ ! -f "$RELEASE_FRAMEWORKS_PATH/$required_library" ]]; then
    echo -e "${RED}The verified release image is missing ${required_library}.${NC}" >&2
    exit 1
  fi
  cp -p "$RELEASE_FRAMEWORKS_PATH/$required_library" "$STAGED_LIB_PATH/"
done < "$REQUIRED_LIBRARIES_PATH"

cp -p "$RELEASE_YT_DLP_PATH" "$STAGED_YT_DLP_PATH"

for required_library in libmpv.2.dylib libavcodec.61.dylib libavformat.61.dylib libavutil.59.dylib libswresample.5.dylib libswscale.8.dylib; do
  if [[ ! -f "$STAGED_LIB_PATH/$required_library" ]]; then
    echo -e "${RED}The verified release image is missing ${required_library}.${NC}" >&2
    exit 1
  fi
done

if [[ "$ARCH" == universal ]]; then
  required_architectures=(arm64 x86_64)
else
  required_architectures=("$ARCH")
fi

for required_architecture in "${required_architectures[@]}"; do
  while IFS= read -r required_library; do
    # These compatibility runtimes are intentionally x86_64-only and are only
    # linked for Intel builds (see Configs/iina.xcconfig).
    if [[ "$required_architecture" == arm64 &&
          ("$required_library" == libgcc_s.1.1.dylib || "$required_library" == libstdc++.6.dylib) ]]; then
      continue
    fi
    lipo -verify_arch "$required_architecture" "$STAGED_LIB_PATH/$required_library"
  done < "$REQUIRED_LIBRARIES_PATH"
  lipo -verify_arch "$required_architecture" "$STAGED_YT_DLP_PATH"
done

hdiutil detach "$MOUNT_PATH" -quiet
DMG_MOUNTED=false

mkdir -p "$LIB_PATH" "$EXEC_PATH"
find "$LIB_PATH" -maxdepth 1 -type f -name '*.dylib' -delete
cp -p "$STAGED_LIB_PATH/"*.dylib "$LIB_PATH/"
cp -p "$STAGED_YT_DLP_PATH" "$YT_DLP_PATH"
chmod 755 "$YT_DLP_PATH"

echo -e "${GREEN}Installed verified ${IINA_RELEASE_VERSION} playback libraries and yt-dlp.${NC}"

mkdir -p "$PLUGIN_PATH"

if [[ "$SKIP_PLUGINS" == true ]]; then
  echo -e "${YELLOW}Skipping official plugin downloads.${NC}"
  echo -e "${GREEN}All downloads completed.${NC}"
  exit 0
fi

fetch_latest_plugin_asset() {
  local repo="$1"
  local response_file
  local status_code

  response_file=$(mktemp) || return 1
  status_code=$(curl -s -L -o "$response_file" -w "%{http_code}" "https://api.github.com/repos/${repo}/releases/latest") || {
    echo -e "${RED}Failed to contact GitHub for ${repo}.${NC}" >&2
    rm -f "$response_file"
    return 1
  }

  if [[ "$status_code" -lt 200 || "$status_code" -ge 300 ]]; then
    echo -e "${RED}GitHub API returned HTTP ${status_code} for ${repo}.${NC}" >&2
    python3 -c '
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace").strip()
if not text:
    raise SystemExit(0)
try:
    payload = json.loads(text)
except json.JSONDecodeError:
    print(text[:240], file=sys.stderr)
    raise SystemExit(0)
message = payload.get("message")
if message:
    print(message, file=sys.stderr)
' "$response_file"
    rm -f "$response_file"
    return 1
  fi

  python3 -c '
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")
try:
    release = json.loads(text)
except json.JSONDecodeError as exc:
    print(f"Failed to decode GitHub API response as JSON: {exc}", file=sys.stderr)
    preview = text.strip()
    if preview:
        print(preview[:240], file=sys.stderr)
    raise SystemExit(1)
assets = [asset for asset in release.get("assets", []) if asset.get("name", "").endswith(".iinaplgz")]
if not assets:
    message = release.get("message")
    if message:
        print(message, file=sys.stderr)
    else:
        print("Latest release does not contain a .iinaplgz asset.", file=sys.stderr)
    raise SystemExit(1)
asset = assets[0]
print(asset["name"])
print(asset["browser_download_url"])
' "$response_file"
  local status=$?
  rm -f "$response_file"
  return $status
}

download_plugin() {
  local repo="$1"
  local prefix="$2"
  local asset_info
  local asset_name
  local asset_url
  local tmp_path

  echo -e "${YELLOW}Downloading latest plugin release for ${repo}...${NC}"
  asset_info=$(fetch_latest_plugin_asset "$repo") || {
    echo -e "${RED}Failed to fetch the latest plugin asset for ${repo}.${NC}" >&2
    return 1
  }

  asset_name=$(printf "%s\n" "$asset_info" | sed -n "1p")
  asset_url=$(printf "%s\n" "$asset_info" | sed -n "2p")
  tmp_path="${PLUGIN_PATH}/${asset_name}.download"

  curl -s -f -L "$asset_url" -o "$tmp_path" || {
    echo -e "${RED}Failed downloading ${asset_name}.${NC}" >&2
    rm -f "$tmp_path"
    return 1
  }

  find "$PLUGIN_PATH" -maxdepth 1 -type f -name "${prefix}-*.iinaplgz" -delete
  mv "$tmp_path" "${PLUGIN_PATH}/${asset_name}"
  echo -e "${GREEN}Downloaded ${asset_name}${NC}"
}

download_plugin "iina/plugin-online-media" "iina-plugin-ytdl" || exit 1
download_plugin "iina/plugin-userscript" "iina-plugin-userscript" || exit 1
download_plugin "iina/plugin-opensub" "iina-plugin-opensub" || exit 1

echo -e "${GREEN}All downloads completed.${NC}"
