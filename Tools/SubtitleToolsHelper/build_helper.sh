#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER_KIND=subtitle exec "$SCRIPT_DIR/../VideoToolsHelper/build_helper.sh"
