#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$project_root/Tools/PlaybackDistributionTests/test_distribution.py"
