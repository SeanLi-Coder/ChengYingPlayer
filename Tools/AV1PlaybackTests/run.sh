#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
exec python3 "$project_root/Tools/AV1PlaybackTests/run.py" "${1:-$project_root/deps}"
