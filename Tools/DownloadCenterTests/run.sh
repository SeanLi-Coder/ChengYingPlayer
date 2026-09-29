#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 -B "$project_root/Tools/DownloadCenterTests/test_runner.py"
exec python3 -B "$project_root/Tools/DownloadCenterTests/run.py"
