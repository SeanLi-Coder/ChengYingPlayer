"""Disable only the origin-rebuild branch to reproduce the previous seek behavior."""
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
needle = """  if (seconds == 0 || (_video && (!CMTIME_IS_NUMERIC(_originVideoStart) ||
      CMTimeCompare(CMTimeMake((int64_t)scaled, AV_TIME_BASE), _originVideoStart) < 0)))
    return [self restartFromOrigin:error];"""
if source.count(needle) != 1:
    raise SystemExit("Expected one exact origin-seek rebuild branch")
Path(sys.argv[2]).write_text(source.replace(needle, "  // Negative control: use the previous indexed-seek path at every target."))
