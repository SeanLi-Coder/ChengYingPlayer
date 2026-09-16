#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENDOR_DIR="$SCRIPT_DIR/vendor/rednote"
OUTPUT_DIR="$REPOSITORY_ROOT/deps/download-center"
HELPER_NAME="chengying-download-center-helper"
HELPER_PYTHON="${HELPER_PYTHON:-python3}"
TARGET_ARCH="${HELPER_TARGET_ARCH:-arm64}"
CODESIGN_IDENTITY="${HELPER_CODESIGN_IDENTITY:--}"

# shellcheck source=other/third_party_sources.sh
source "$REPOSITORY_ROOT/other/third_party_sources.sh"

if [[ "$(uname -s)" != "Darwin" || "$TARGET_ARCH" != "arm64" ]]; then
  echo "The pinned download-center runtime currently supports macOS arm64 builds only." >&2
  exit 2
fi
if [[ "${HELPER_REQUIRE_SIGNING:-0}" == "1" && "$CODESIGN_IDENTITY" == "-" ]]; then
  echo "HELPER_CODESIGN_IDENTITY is required for a distribution-signed build." >&2
  exit 2
fi
"$HELPER_PYTHON" - "$SCRIPT_DIR/runtime-artifacts.json" "$PYTHON_VERSION" \
  "altgraph=$ALTGRAPH_VERSION" "macholib=$MACHOLIB_VERSION" "packaging=$PACKAGING_VERSION" \
  "pyinstaller=$PYINSTALLER_VERSION" "pyinstaller-hooks-contrib=$PYINSTALLER_HOOKS_VERSION" \
  "setuptools=$SETUPTOOLS_VERSION" <<'PY'
import importlib.metadata
import json
import platform
import sys
from pathlib import Path

manifest_path, python_version, *build_specs = sys.argv[1:]
if platform.python_version() != python_version or platform.machine() != "arm64":
    raise SystemExit(f"A native arm64 CPython {python_version} build environment is required.")
manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
expected = {package["name"]: package["version"] for package in manifest["artifacts"]}
expected.update(spec.split("=", 1) for spec in build_specs)
for package, version in expected.items():
    actual = importlib.metadata.version(package)
    if actual != version:
        raise SystemExit(f"Install the pinned build lock: {package} {version} is required, found {actual}.")
PY

for required in helper.py host.py bundle_smoke.py runtime-artifacts.json vendor/rednote/app/main.py; do
  if [[ ! -s "$SCRIPT_DIR/$required" ]]; then
    echo "Required helper source is unavailable: $required" >&2
    exit 2
  fi
done
"$HELPER_PYTHON" "$SCRIPT_DIR/verify_vendor.py"
mkdir -p "$REPOSITORY_ROOT/deps"
WORK_DIR="$(mktemp -d "$REPOSITORY_ROOT/deps/.download-center-build.XXXXXX")"
cleanup() {
  if [[ "$WORK_DIR" == "$REPOSITORY_ROOT/deps/.download-center-build."* && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT
mkdir -p "$WORK_DIR/vendor/rednote"
rsync -a --exclude '__pycache__' --exclude '.pytest_cache' "$VENDOR_DIR/" "$WORK_DIR/vendor/rednote/"
VENDOR_DIR="$WORK_DIR/vendor/rednote"

DENO_SOURCE="$("$HELPER_PYTHON" -c 'from deno import find_deno_bin; print(find_deno_bin())')"
install -m 755 "$DENO_SOURCE" "$WORK_DIR/deno"
codesign --force --sign "$CODESIGN_IDENTITY" --options runtime \
  --entitlements "$SCRIPT_DIR/runtime-entitlements.plist" "$WORK_DIR/deno"
"$HELPER_PYTHON" "$SCRIPT_DIR/collect_licenses.py" "$WORK_DIR/Legal"

PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$VENDOR_DIR:$SCRIPT_DIR" \
  PYINSTALLER_STRICT_BUNDLE_CODESIGN_ERROR=1 PYINSTALLER_VERIFY_BUNDLE_SIGNATURE=1 \
  CHENGYING_HELPER_SOURCE_DIR="$SCRIPT_DIR" CHENGYING_HELPER_VENDOR_DIR="$VENDOR_DIR" \
  CHENGYING_HELPER_LEGAL_DIR="$WORK_DIR/Legal" CHENGYING_HELPER_DENO="$WORK_DIR/deno" \
  CHENGYING_HELPER_SIGNING_IDENTITY="$CODESIGN_IDENTITY" CHENGYING_HELPER_TARGET_ARCH="$TARGET_ARCH" \
  "$HELPER_PYTHON" -m PyInstaller --clean --noconfirm \
    --distpath "$WORK_DIR/dist" --workpath "$WORK_DIR/work" "$SCRIPT_DIR/download_center.spec"
BUILT_APP="$WORK_DIR/dist/DownloadCenter.app"
BUILT_CONTENTS="$BUILT_APP/Contents"
"$HELPER_PYTHON" "$SCRIPT_DIR/verify_vendor.py" \
  --vendor-root "$BUILT_CONTENTS/Resources/vendor/rednote" --manifest "$SCRIPT_DIR/upstream-manifest.json"

# Re-sign the real executable leaves and then their helper bundle, inside out.
# Scripts remain sealed resources; no recursive signing workaround is used here.
for binary in "$BUILT_CONTENTS/MacOS/deno" "$BUILT_CONTENTS/Frameworks/playwright/driver/node" "$BUILT_CONTENTS/MacOS/$HELPER_NAME"; do
  if [[ ! -x "$binary" ]]; then
    echo "A required frozen executable is missing: $binary" >&2
    exit 3
  fi
  if [[ " $(lipo -archs "$binary") " != *" $TARGET_ARCH "* ]]; then
    echo "Frozen executable architecture mismatch: $binary" >&2
    exit 3
  fi
  codesign --force --sign "$CODESIGN_IDENTITY" --options runtime \
    --entitlements "$SCRIPT_DIR/runtime-entitlements.plist" "$binary"
  codesign --verify --strict "$binary"
done
codesign --force --sign "$CODESIGN_IDENTITY" --options runtime \
  --entitlements "$SCRIPT_DIR/runtime-entitlements.plist" "$BUILT_APP"
codesign --verify --deep --strict "$BUILT_APP"

"$BUILT_CONTENTS/MacOS/$HELPER_NAME" --help >/dev/null
PATH="$BUILT_CONTENTS/MacOS:$PATH" "$BUILT_CONTENTS/MacOS/$HELPER_NAME" --self-test
if [[ -n "$(find "$BUILT_APP" -type d -name '__pycache__' -print -quit)" ]]; then
  echo "The frozen download center must not contain generated Python bytecode caches." >&2
  exit 3
fi
mkdir "$WORK_DIR/output"
mv "$BUILT_APP" "$WORK_DIR/output/DownloadCenter.app"

# A successful, verified build replaces only the previous generated helper directory.
if [[ -e "$OUTPUT_DIR" ]]; then
  mv "$OUTPUT_DIR" "$WORK_DIR/previous"
fi
if ! mv "$WORK_DIR/output" "$OUTPUT_DIR"; then
  if [[ -d "$WORK_DIR/previous" ]]; then
    mv "$WORK_DIR/previous" "$OUTPUT_DIR"
  fi
  exit 4
fi
printf '%s\n' "$OUTPUT_DIR/DownloadCenter.app/Contents/MacOS/$HELPER_NAME"
