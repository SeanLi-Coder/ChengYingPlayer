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

PYINSTALLER_ARGS=(
  --clean --noconfirm --onedir --contents-directory _internal
  --name "$HELPER_NAME"
  --distpath "$WORK_DIR/dist"
  --workpath "$WORK_DIR/work"
  --specpath "$WORK_DIR/spec"
  --target-arch "$TARGET_ARCH"
  --codesign-identity "$CODESIGN_IDENTITY"
  --osx-entitlements-file "$SCRIPT_DIR/runtime-entitlements.plist"
  --paths "$VENDOR_DIR"
  --paths "$SCRIPT_DIR"
  --hidden-import bundle_smoke
  --add-data "$VENDOR_DIR:vendor/rednote"
  --add-data "$VENDOR_DIR/app/static:app/static"
  --add-data "$SCRIPT_DIR/static:static"
  --add-data "$SCRIPT_DIR/runtime-artifacts.json:."
  --add-data "$SCRIPT_DIR/upstream-manifest.json:."
)
# The original engine is imported dynamically from the preserved source tree.
# Collect the complete engine and its dynamic extractor/JS/browser dependencies.
for package in app yt_dlp yt_dlp_ejs playwright uvicorn fastapi starlette pydantic \
  pydantic_core requests urllib3 websockets Cryptodome certifi truststore mutagen; do
  PYINSTALLER_ARGS+=(--collect-all "$package")
done
while IFS= read -r package; do
  PYINSTALLER_ARGS+=(--copy-metadata "$package")
done < <("$HELPER_PYTHON" - "$SCRIPT_DIR/runtime-artifacts.json" <<'PY'
import json
import sys
from pathlib import Path
for package in json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["artifacts"]:
    print(package["name"])
PY
)

PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$VENDOR_DIR:$SCRIPT_DIR" \
  "$HELPER_PYTHON" -m PyInstaller "${PYINSTALLER_ARGS[@]}" "$SCRIPT_DIR/helper.py"
BUILT_DIR="$WORK_DIR/dist/$HELPER_NAME"
"$HELPER_PYTHON" "$SCRIPT_DIR/verify_vendor.py" \
  --vendor-root "$BUILT_DIR/_internal/vendor/rednote" --manifest "$SCRIPT_DIR/upstream-manifest.json"
DENO_SOURCE="$("$HELPER_PYTHON" -c 'from deno import find_deno_bin; print(find_deno_bin())')"
install -m 755 "$DENO_SOURCE" "$BUILT_DIR/deno"
"$HELPER_PYTHON" "$SCRIPT_DIR/collect_licenses.py" "$BUILT_DIR/Legal"

# Playwright's Node is package data, and Deno is installed separately from Python modules.
# Sign both explicitly with their own JIT permissions; never broaden the main app's entitlements.
for binary in "$BUILT_DIR/deno" "$BUILT_DIR/_internal/playwright/driver/node" "$BUILT_DIR/$HELPER_NAME"; do
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

"$BUILT_DIR/$HELPER_NAME" --help >/dev/null
PATH="$BUILT_DIR:$PATH" "$BUILT_DIR/$HELPER_NAME" --self-test
if [[ -n "$(find "$BUILT_DIR" -type d -name '__pycache__' -print -quit)" ]]; then
  echo "The frozen download center must not contain generated Python bytecode caches." >&2
  exit 3
fi

# A successful, verified build replaces only the previous generated helper directory.
if [[ -e "$OUTPUT_DIR" ]]; then
  mv "$OUTPUT_DIR" "$WORK_DIR/previous"
fi
if ! mv "$BUILT_DIR" "$OUTPUT_DIR"; then
  if [[ -d "$WORK_DIR/previous" ]]; then
    mv "$WORK_DIR/previous" "$OUTPUT_DIR"
  fi
  exit 4
fi
printf '%s\n' "$OUTPUT_DIR/$HELPER_NAME"
