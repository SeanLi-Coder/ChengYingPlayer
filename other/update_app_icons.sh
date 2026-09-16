#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MASTER_ICON="$PROJECT_ROOT/Brand/ChengYingIconMaster.png"
ASSET_ROOT="$PROJECT_ROOT/iina/Assets.xcassets"
HOME_ICON_DIR="$ASSET_ROOT/Icons/iina_arrow.imageset"
CHECK_ONLY=false
STAGING_DIR=""

usage() {
  echo "Usage: $0 [--check]"
  echo "Resize the brand master into application icon assets, or validate them without changes."
}

fail() {
  echo "Icon asset error: $*" >&2
  exit 1
}

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi
case "${1:-}" in
  "") ;;
  --check) CHECK_ONLY=true ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

for command_name in sips plutil cmp cp mktemp rm rmdir; do
  command -v "$command_name" >/dev/null 2>&1 || fail "Required command is unavailable: $command_name"
done

ICON_SETS=(AppIcon AppIconDebug AppIconBeta AppIconNightly)
# Each entry contains the filename, logical size, scale, and pixel dimensions.
ICON_SPECS=(
  "icon_16x16.png 16x16 1x 16"
  "icon_16x16@2x.png 16x16 2x 32"
  "icon_32x32.png 32x32 1x 32"
  "icon_32x32@2x.png 32x32 2x 64"
  "icon_128x128.png 128x128 1x 128"
  "icon_128x128@2x.png 128x128 2x 256"
  "icon_256x256.png 256x256 1x 256"
  "icon_256x256@2x.png 256x256 2x 512"
  "icon_512x512.png 512x512 1x 512"
  "icon_512x512@2x.png 512x512 2x 1024"
)
PIXEL_SIZES=(16 32 64 128 256 512 1024)

inspect_image() {
  local image_path="$1" expected_size="$2"
  local metadata key value width="" height="" format="" alpha=""
  [[ -f "$image_path" ]] || fail "Missing image: $image_path"
  metadata="$(sips -g pixelWidth -g pixelHeight -g format -g hasAlpha "$image_path")" || fail "Cannot read image: $image_path"
  while IFS=: read -r key value; do
    key="${key//[[:space:]]/}"
    value="${value//[[:space:]]/}"
    case "$key" in
      pixelWidth) width="$value" ;;
      pixelHeight) height="$value" ;;
      format) format="$value" ;;
      hasAlpha) alpha="$value" ;;
    esac
  done <<< "$metadata"
  [[ "$format" == png && "$alpha" == yes ]] || fail "A PNG with an alpha channel is required: $image_path"
  [[ "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ && "$width" == "$height" ]] || fail "A square image is required: $image_path"
  if [[ "$expected_size" == master ]]; then
    [[ "$width" -ge 1024 ]] || fail "The master must be at least 1024 by 1024 pixels."
  else
    [[ "$width" == "$expected_size" ]] || fail "Expected $expected_size by $expected_size pixels, found $width by $height: $image_path"
  fi
}

expect_manifest_value() {
  local manifest="$1" key_path="$2" expected="$3" actual
  actual="$(plutil -extract "$key_path" raw -o - "$manifest")" || fail "Cannot read $key_path in $manifest"
  [[ "$actual" == "$expected" ]] || fail "Unexpected $key_path in $manifest: expected $expected, found $actual"
}

validate_manifests() {
  local icon_set manifest index spec filename logical_size scale pixel_size
  for icon_set in "${ICON_SETS[@]}"; do
    manifest="$ASSET_ROOT/$icon_set.appiconset/Contents.json"
    [[ -f "$manifest" ]] || fail "Missing asset manifest: $manifest"
    plutil -convert xml1 -o - "$manifest" >/dev/null || fail "Invalid asset manifest: $manifest"
    expect_manifest_value "$manifest" images 10
    index=0
    for spec in "${ICON_SPECS[@]}"; do
      read -r filename logical_size scale pixel_size <<< "$spec"
      expect_manifest_value "$manifest" "images.$index.filename" "$filename"
      expect_manifest_value "$manifest" "images.$index.size" "$logical_size"
      expect_manifest_value "$manifest" "images.$index.scale" "$scale"
      expect_manifest_value "$manifest" "images.$index.idiom" mac
      index=$((index + 1))
    done
  done
  manifest="$HOME_ICON_DIR/Contents.json"
  [[ -f "$manifest" ]] || fail "Missing home-screen asset manifest: $manifest"
  plutil -convert xml1 -o - "$manifest" >/dev/null || fail "Invalid asset manifest: $manifest"
  expect_manifest_value "$manifest" images.1.filename iina-arrow.png
  expect_manifest_value "$manifest" images.1.scale 2x
  expect_manifest_value "$manifest" images.1.idiom universal
}

validate_renditions() {
  local icon_set spec filename logical_size scale pixel_size image_path reference_path
  for spec in "${ICON_SPECS[@]}"; do
    read -r filename logical_size scale pixel_size <<< "$spec"
    reference_path="$ASSET_ROOT/AppIcon.appiconset/$filename"
    for icon_set in "${ICON_SETS[@]}"; do
      image_path="$ASSET_ROOT/$icon_set.appiconset/$filename"
      inspect_image "$image_path" "$pixel_size"
      cmp -s "$reference_path" "$image_path" || fail "Icon variants do not match: $image_path"
    done
  done
  inspect_image "$HOME_ICON_DIR/iina-arrow.png" 1024
  cmp -s "$ASSET_ROOT/AppIcon.appiconset/icon_512x512@2x.png" "$HOME_ICON_DIR/iina-arrow.png" || fail "The home-screen icon does not match the application icon."
}

cleanup() {
  local pixel_size
  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
    for pixel_size in "${PIXEL_SIZES[@]}"; do
      rm -f "$STAGING_DIR/$pixel_size.png"
    done
    rmdir "$STAGING_DIR"
  fi
}

inspect_image "$MASTER_ICON" master
validate_manifests

if [[ "$CHECK_ONLY" == true ]]; then
  validate_renditions
  echo "Validated 40 macOS app icon renditions and the home-screen icon."
  exit 0
fi

# Stage and validate all sizes before replacing any existing application assets.
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chengying-app-icons.XXXXXX")"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for pixel_size in "${PIXEL_SIZES[@]}"; do
  sips -z "$pixel_size" "$pixel_size" "$MASTER_ICON" --out "$STAGING_DIR/$pixel_size.png" >/dev/null
  inspect_image "$STAGING_DIR/$pixel_size.png" "$pixel_size"
done
for icon_set in "${ICON_SETS[@]}"; do
  for spec in "${ICON_SPECS[@]}"; do
    read -r filename logical_size scale pixel_size <<< "$spec"
    cp "$STAGING_DIR/$pixel_size.png" "$ASSET_ROOT/$icon_set.appiconset/$filename"
  done
done
cp "$STAGING_DIR/1024.png" "$HOME_ICON_DIR/iina-arrow.png"
validate_renditions
echo "Updated 40 macOS app icon renditions and the home-screen icon from the brand master."
