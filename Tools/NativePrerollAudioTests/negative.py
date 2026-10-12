"""Disable only the new cross-stream holding condition for a negative control."""
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
mode = sys.argv[3]
if mode == "1":
    changes = [("if preroll && !hasVideo && media.hasVideo && !isVideo &&",
                "if false && preroll && !hasVideo && media.hasVideo && !isVideo &&", 1)]
elif mode == "flush":
    changes = [("guard !output.isFlushingVideo, output.actualRate == 0, anchored.isFinite,",
                "guard output.actualRate == 0, anchored.isFinite,", 1),
               ("if !preroll || hasVideo, try !drainHeldPrerollAudio(clock: clock, budget: &budget)",
                "if !preroll, try !drainHeldPrerollAudio(clock: clock, budget: &budget)", 2)]
else:
    raise SystemExit("Expected negative mode 1 or flush")
for needle, replacement, count in changes:
    if source.count(needle) != count:
        raise SystemExit(f"Unexpected source landmark count: {needle}")
    source = source.replace(needle, replacement)
pathlib.Path(sys.argv[2]).write_text(source)
