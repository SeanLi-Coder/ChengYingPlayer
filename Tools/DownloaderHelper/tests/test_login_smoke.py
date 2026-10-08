"""Validate the frozen-runtime private login check using synthetic data only."""

import sys
from pathlib import Path

sys.path[:0] = [str(Path(__file__).resolve().parents[1]),
               str(Path(__file__).resolve().parents[1] / "vendor/rednote")]

from login_smoke import verify_login_runtime


def test_login_runtime():
    assert verify_login_runtime() == "isolated-revisions-and-restart-verified-offline"
