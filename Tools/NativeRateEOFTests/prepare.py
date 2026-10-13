#!/usr/bin/env python3
"""Apply only the pre-fix EOF-rate behavior to a copied production Session."""
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
old = """        if self.phase == .ended {
          self.publish(force: true)
          return
        }
"""
if source.count(old) != 1:
    raise SystemExit("EOF-rate negative-control landmark is not unique")
Path(sys.argv[2]).write_text(source.replace(old, "", 1))
