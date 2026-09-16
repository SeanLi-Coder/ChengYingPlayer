#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$PROJECT_ROOT/deps/download-center/DownloadCenter.app"
if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${CONTENTS_FOLDER_PATH:-}" ]]; then
  echo "This script must run as an application Xcode build phase." >&2
  exit 2
fi
DESTINATION="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/DownloadCenter.app"
LEGACY_DESTINATION="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/DownloadCenter"
read -r -a BUILD_ARCHS <<< "${ARCHS:-}"
if [[ "${#BUILD_ARCHS[@]}" == "1" && "${BUILD_ARCHS[0]}" == "x86_64" ]]; then
  # Remove only this generated helper when Xcode reuses a previous ARM build directory.
  if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
    rm -rf -- "$DESTINATION"
  fi
  if [[ -e "$LEGACY_DESTINATION" || -L "$LEGACY_DESTINATION" ]]; then
    rm -rf -- "$LEGACY_DESTINATION"
  fi
  echo "Skipping the ARM-only download center for this Intel application build."
  exit 0
fi
if [[ "${#BUILD_ARCHS[@]}" != "1" || "${BUILD_ARCHS[0]:-}" != "arm64" ]]; then
  echo "Download-center embedding requires ARCHS=arm64; universal builds are not supported." >&2
  exit 2
fi
if [[ ! -x "$SOURCE_DIR/Contents/MacOS/chengying-download-center-helper" || ! -d "$SOURCE_DIR/Contents/Frameworks" || ! -x "$SOURCE_DIR/Contents/Frameworks/playwright/driver/node" ]]; then
  echo "Build the complete download center with Tools/DownloaderHelper/build_helper.sh first." >&2
  exit 2
fi
mkdir -p "$(dirname "$DESTINATION")"
STAGING_DIR="$(mktemp -d "$(dirname "$DESTINATION")/.DownloadCenter-stage.XXXXXX")"
cleanup() {
  if [[ "$STAGING_DIR" == "$(dirname "$DESTINATION")/.DownloadCenter-stage."* && -d "$STAGING_DIR" ]]; then
    rm -rf -- "$STAGING_DIR"
  fi
}
trap cleanup EXIT
ditto --noqtn "$SOURCE_DIR" "$STAGING_DIR/DownloadCenter.app"
codesign --verify --deep --strict "$STAGING_DIR/DownloadCenter.app"
if [[ -e "$DESTINATION" ]]; then
  mv "$DESTINATION" "$STAGING_DIR/previous"
fi
if ! mv "$STAGING_DIR/DownloadCenter.app" "$DESTINATION"; then
  if [[ -d "$STAGING_DIR/previous" ]]; then
    mv "$STAGING_DIR/previous" "$DESTINATION"
  fi
  exit 3
fi
if [[ -e "$LEGACY_DESTINATION" || -L "$LEGACY_DESTINATION" ]]; then
  rm -rf -- "$LEGACY_DESTINATION"
fi
codesign --verify --deep --strict "$DESTINATION"
