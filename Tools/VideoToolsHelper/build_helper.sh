#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="$REPOSITORY_ROOT/deps/executable"
HELPER_PYTHON="${HELPER_PYTHON:-python3}"
TARGET_ARCH="${HELPER_TARGET_ARCH:-}"
CODESIGN_IDENTITY="${HELPER_CODESIGN_IDENTITY:-}"
REQUIRE_SIGNING="${HELPER_REQUIRE_SIGNING:-0}"
HELPER_KIND="${HELPER_KIND:-video}"
case "$HELPER_KIND" in
  video) HELPER_SOURCE_DIR="$SCRIPT_DIR" ;;
  subtitle) HELPER_SOURCE_DIR="$REPOSITORY_ROOT/Tools/SubtitleToolsHelper" ;;
  *) echo "Unsupported helper kind: $HELPER_KIND" >&2; exit 2 ;;
esac
HELPER_NAME="chengying-$HELPER_KIND-tools-helper"

# shellcheck source=other/third_party_sources.sh
source "$REPOSITORY_ROOT/other/third_party_sources.sh"

if ! "$HELPER_PYTHON" - \
  "$PYTHON_VERSION" \
  "altgraph=$ALTGRAPH_VERSION" \
  "macholib=$MACHOLIB_VERSION" \
  "packaging=$PACKAGING_VERSION" \
  "pyinstaller=$PYINSTALLER_VERSION" \
  "pyinstaller-hooks-contrib=$PYINSTALLER_HOOKS_VERSION" \
  "setuptools=$SETUPTOOLS_VERSION" <<'PY'
import importlib.metadata
import platform
import sys

expected_python, *package_specs = sys.argv[1:]
if platform.python_version() != expected_python:
    raise SystemExit(
        f"Python {expected_python} is required; found {platform.python_version()}."
    )

for package_spec in package_specs:
    package_name, expected_version = package_spec.split("=", 1)
    try:
        actual_version = importlib.metadata.version(package_name)
    except importlib.metadata.PackageNotFoundError:
        raise SystemExit(f"Required build package is missing: {package_name}") from None
    if actual_version != expected_version:
        raise SystemExit(
            f"{package_name} {expected_version} is required; found {actual_version}."
        )
PY
then
  echo "Install the checksum-pinned helper toolchain from requirements-build.txt." >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.chengying-helper-build.XXXXXX")"
DIST_DIR="$WORK_DIR/dist"
PARTIAL_PATH="$OUTPUT_DIR/.$HELPER_NAME.partial-$$"

cleanup() {
  rm -rf "$WORK_DIR"
  rm -f "$PARTIAL_PATH"
}
trap cleanup EXIT

if [[ "$REQUIRE_SIGNING" == "1" && -z "$CODESIGN_IDENTITY" ]]; then
  echo "HELPER_CODESIGN_IDENTITY is required for this build." >&2
  exit 2
fi

PYINSTALLER_ARGS=(
  --clean
  --noconfirm
  --onefile
  --name "$HELPER_NAME"
  --distpath "$DIST_DIR"
  --workpath "$WORK_DIR/work"
  --specpath "$WORK_DIR/spec"
)

if [[ "$HELPER_KIND" == "subtitle" ]]; then
  PYINSTALLER_ARGS+=(
    --add-data "$HELPER_SOURCE_DIR/assets.json:."
  )
  for worker_source in "$HELPER_SOURCE_DIR"/subtitle_worker/*.py; do
    PYINSTALLER_ARGS+=(--add-data "$worker_source:subtitle_worker")
  done
fi

if [[ -n "$TARGET_ARCH" ]]; then
  PYINSTALLER_ARGS+=(--target-arch "$TARGET_ARCH")
fi

if [[ -n "$CODESIGN_IDENTITY" ]]; then
  PYINSTALLER_ARGS+=(--codesign-identity "$CODESIGN_IDENTITY")
fi

"$HELPER_PYTHON" -m PyInstaller \
  "${PYINSTALLER_ARGS[@]}" \
  "$HELPER_SOURCE_DIR/helper.py"

BUILT_HELPER="$DIST_DIR/$HELPER_NAME"
HELPER_PATH="$OUTPUT_DIR/$HELPER_NAME"
if [[ ! -x "$BUILT_HELPER" ]]; then
  echo "Helper build did not produce an executable: $BUILT_HELPER" >&2
  exit 3
fi

BUILT_ARCHS="$(lipo -archs "$BUILT_HELPER")"
EXPECTED_ARCH="${TARGET_ARCH:-$(uname -m)}"
if [[ "$EXPECTED_ARCH" == "universal2" ]]; then
  if [[ "$BUILT_ARCHS" != *"arm64"* || "$BUILT_ARCHS" != *"x86_64"* ]]; then
    echo "Universal helper is missing an architecture: $BUILT_ARCHS" >&2
    exit 4
  fi
elif [[ " $BUILT_ARCHS " != *" $EXPECTED_ARCH "* ]]; then
  echo "Helper architecture mismatch: expected $EXPECTED_ARCH, got $BUILT_ARCHS" >&2
  exit 4
fi

codesign --verify --strict "$BUILT_HELPER"

BUNDLED_FFMPEG="$OUTPUT_DIR/ffmpeg"
BUNDLED_FFPROBE="$OUTPUT_DIR/ffprobe"
if [[ -x "$BUNDLED_FFMPEG" && -x "$BUNDLED_FFPROBE" ]]; then
  SMOKE_ARGS=()
  SMOKE_COMMAND=ping
  SMOKE_EVENT=pong
  if [[ "$HELPER_KIND" == "subtitle" ]]; then
    SMOKE_ARGS+=(--data-dir "$WORK_DIR/smoke-data")
    SMOKE_COMMAND=status
    SMOKE_EVENT=status
  fi
  SMOKE_OUTPUT="$({
    printf '{"id":"build-ping","command":"%s"}\n' "$SMOKE_COMMAND"
    printf '%s\n' '{"id":"build-shutdown","command":"shutdown"}'
  } | "$BUILT_HELPER" \
    --ffmpeg "$BUNDLED_FFMPEG" \
    --ffprobe "$BUNDLED_FFPROBE" \
    "${SMOKE_ARGS[@]}" \
    --stdio)"
  if ! grep -Eq '"type"[[:space:]]*:[[:space:]]*"ready"' <<<"$SMOKE_OUTPUT" || \
     ! grep -Eq "\"type\"[[:space:]]*:[[:space:]]*\"$SMOKE_EVENT\"" <<<"$SMOKE_OUTPUT"; then
    echo "Frozen helper smoke test failed." >&2
    exit 5
  fi
fi

mv "$BUILT_HELPER" "$PARTIAL_PATH"
chmod 755 "$PARTIAL_PATH"
mv -f "$PARTIAL_PATH" "$HELPER_PATH"

echo "$HELPER_PATH"
