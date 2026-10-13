#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
exec python3 -B Tools/NativeAV1Tests/run.py "$@"
