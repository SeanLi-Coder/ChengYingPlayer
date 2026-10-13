"""Add observation-only counters to a copied session; never change its decisions."""
from pathlib import Path
import argparse
import subprocess


def instrument(source):
    replacements = {
        "  private func pump() {\n": "  private func pump() {\n    SeekTrace.shared.beginPump()\n    defer { SeekTrace.shared.endPump() }\n",
        "    worker.asyncAfter(deadline: .now() + delay)": "    SeekTrace.shared.schedule(delay)\n    worker.asyncAfter(deadline: .now() + delay)",
        "if pending == nil { pending = try decoder.readSample() }": "if pending == nil { SeekTrace.shared.read(); pending = try decoder.readSample() }",
        "        case .beforeRange:\n": "        case .beforeRange:\n          SeekTrace.shared.discard()\n",
    }
    for old, new in replacements.items():
        if source.count(old) != 1:
            raise ValueError("Session observation boundary is not unique: " + old)
        source = source.replace(old, new, 1)
    return source


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--revision")
    parser.add_argument("--negative", choices=["polling", "busy-wait", "quantum", "fifo"])
    parser.add_argument("--uninstrumented", action="store_true")
    args = parser.parse_args()
    source = (subprocess.check_output(["git", "show", args.revision + ":iina/NativePlayback/NativePlaybackSession.swift"],
                                     text=True) if args.revision else args.source.read_text())
    if args.negative:
        changes = {
            "polling": ("schedulePump(after: activePreroll ? .milliseconds(0) : .milliseconds(10))", "schedulePump()"),
            "busy-wait": ("schedulePump(after: activePreroll ? .milliseconds(0) : .milliseconds(10))",
                          "schedulePump(after: .milliseconds(0))"),
            "quantum": ("if preroll && budget < 8 && ProcessInfo.processInfo.systemUptime >= quantumDeadline {", "if false {"),
            "fifo": ("if !wantsPlayback && !hasAudio, heldPrerollAudioHead < heldPrerollAudio.count,",
                     "if false, heldPrerollAudioHead < heldPrerollAudio.count,"),
        }
        old, new = changes[args.negative]
        if source.count(old) != 1:
            raise ValueError("Negative-control boundary changed")
        source = source.replace(old, new, 1)
    if args.uninstrumented and args.negative:
        raise ValueError("Negative controls require observation counters")
    args.destination.write_text(source if args.uninstrumented else instrument(source))
