#!/usr/bin/env python3
"""Compile production event dispatch and inject delayed events without user media."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def section(text, start, end):
    if text.count(start) != 1:
        raise RuntimeError(f"Production boundary changed: {start}")
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sanitize", choices=["address", "thread"])
    parser.add_argument("--negative-control", choices=["epoch", "first-start"])
    args = parser.parse_args()
    source = (ROOT / "iina/MPVController.swift").read_text()
    core = (ROOT / "iina/PlayerCore.swift").read_text()
    route = section(source, "  // MARK: - Playback route event ownership", "  // MARK: - End playback route event ownership")
    events = section(source, "  // Read event and handle it async\n", "  // MARK: - User Options")
    hook = section(source, "  private func addSavedLoopModeHook()", "  /// Start each newly loaded video silently")
    commands = section(source, "  private func makeCArgs(", "  func observe(property:")
    setters = section(source, "  // Set property\n", "  func getEnum<")
    properties = section(source, "  let observeProperties:", "  /// Map from mpv codec name")
    gate_start = core.index("  @Atomic private var playbackEventRoute")
    gate_end = core.index("\n  }\n", core.index("  func noteMPVMediaCommand()", gate_start)) + len("\n  }\n")
    gate = core[gate_start:gate_end]
    lines = events.splitlines()
    for index, line in enumerate(lines):
        if "DispatchQueue.main.async" not in line:
            continue
        following = "\n".join(lines[index + 1:index + 4])
        if "acceptsMPVEventRevision(revision)" not in following and "self.player.mpvHasShutdown()" not in following:
            raise RuntimeError("Every media callback needs a delivery-time epoch check; only shutdown is unconditional")
    for prefix in ["func command(_ command:", "func asyncCommand(_ command:"]:
        body = section(source, "  " + prefix, "\n  }\n")
        if body.index("noteMediaCommand(command, args: args)") > body.index("let returnValue = mpv_command"):
            raise RuntimeError("Media history must be recorded before submitting a command")
    if "player.noteMPVMediaCommand()" not in section(source, "  func command(rawString:", "\n  }\n"):
        raise RuntimeError("Raw commands must invalidate fresh-core eligibility")
    if "noteMediaProperty(name)" not in section(source, "  func setNode(", "\n  }\n"):
        raise RuntimeError("Node-based playlist writes must invalidate fresh-core eligibility")
    generated = "import Cocoa\nimport QuartzCore\n" + "final class MPVController: RoutingControllerFixture {\n"
    generated += route + properties + commands + setters + hook + events + "\n}\n"
    generated = generated.replace("private ", "")
    player = "import Foundation\nfinal class PlayerCore: RoutingPlayerFixture {\n" + gate.replace("private ", "") + "\n}\n"
    if args.negative_control == "epoch":
        original = "$0.acceptsMPV && $0.revision == revision"
        if original not in player:
            raise RuntimeError("Epoch negative-control boundary changed")
        player = player.replace(original, "$0.acceptsMPV && ($0.revision == revision || true)")
    elif args.negative_control == "first-start":
        if "awaitingFirstRoutedStart = true" not in generated:
            raise RuntimeError("First-start negative-control boundary changed")
        generated = generated.replace("awaitingFirstRoutedStart = true", "awaitingFirstRoutedStart = false")
    with tempfile.TemporaryDirectory(prefix="chengying-routing-") as directory:
        work = Path(directory)
        media = work / "synthetic.wav"
        subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                        "-i", "anullsrc=r=8000:cl=mono", "-t", "0.05", str(media)], check=True, timeout=20)
        (work / "Production.swift").write_text(generated)
        (work / "Player.swift").write_text(player)
        executable = work / "RoutingTests"
        command = ["xcrun", "swiftc", "-warnings-as-errors", "-o", str(executable),
                   "-import-objc-header", str(ROOT / "deps/include/mpv/client.h")]
        if args.sanitize:
            command += ["-sanitize=" + args.sanitize]
        command += [str(ROOT / path) for path in ["iina/Atomic.swift", "iina/Lock.swift", "iina/MPVOption.swift",
                    "iina/MPVProperty.swift", "iina/MPVCommand.swift", "iina/MPVHook.swift",
                    "Tools/PlaybackBackendRoutingTests/Boundary.swift", "Tools/PlaybackBackendRoutingTests/main.swift"]]
        command += [str(work / "Production.swift"), str(work / "Player.swift"),
                    str(ROOT / "deps/lib/libmpv.2.dylib"), "-Xlinker", "-rpath", "-Xlinker", str(ROOT / "deps/lib")]
        subprocess.run(command, check=True, timeout=90)
        if args.negative_control:
            result = subprocess.run([str(executable), str(media)], capture_output=True, text=True, timeout=35)
            expected = {"epoch": "Old queued callbacks cannot alias a new MPV epoch",
                        "first-start": "First-load barrier rejects startup properties before START_FILE"}[args.negative_control]
            if result.returncode != 1 or "FAIL: " + expected not in result.stderr:
                raise RuntimeError("Negative control did not fail at the intended invariant: " + result.stderr)
            print("PASS: Negative control rejected: " + expected)
        else:
            subprocess.run([str(executable), str(media)], check=True, timeout=35)


if __name__ == "__main__":
    main()
