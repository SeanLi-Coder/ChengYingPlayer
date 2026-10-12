"""Force exactly one readback verdict to fail, without changing its deadline."""

from pathlib import Path
import sys

source, destination = map(Path, sys.argv[1:])
text = source.read_text()
old = "return observed?.image == expected && !expected.isEmpty && observed?.rate == 0"
new = ('return label != "Seek shows a current video image" && '
       'observed?.image == expected && !expected.isEmpty && observed?.rate == 0')
if text.count(old) != 1:
    raise SystemExit("Readback verdict landmark must occur exactly once")
destination.write_text(text.replace(old, new, 1))
print("NEGATIVE CONTROL: one lifecycle readback verdict is forced false; source, samples and the three-second deadline are unchanged.")
