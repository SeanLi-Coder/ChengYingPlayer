#!/usr/bin/env python3
"""Exercise actual PlayerCore retirement with controlled asynchronous sessions."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def method(source, name):
    for prefix in ("  private func ", "  func "):
        signature = prefix + name + "("
        if signature in source:
            begin = source.index(signature)
            end = source.index("\n  }", begin) + len("\n  }")
            attribute = source.rfind("\n", 0, begin - 1) + 1
            if source[attribute:begin].strip() == "@discardableResult":
                begin = attribute
            return source[begin:end]
    raise RuntimeError("Production method not found: " + name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sanitize", choices=["address", "thread"])
    parser.add_argument("--negative-control", action="store_true")
    parser.add_argument("--capture-negative-control", action="store_true")
    args = parser.parse_args()
    core = (ROOT / "iina/PlayerCore.swift").read_text()
    info = (ROOT / "iina/PlaybackInfo.swift").read_text()
    gate_start = core.index("  @Atomic private var playbackEventRoute")
    gate_end = core.index("\n  }", core.index("  func noteMPVMediaCommand()", gate_start)) + len("\n  }")
    fields_start = core.index("  private var nativeTransport:")
    fields_end = core.index("  private var playbackTransport:", fields_start)
    # The lifecycle fixture has no active clip preview. Keep all lifecycle and
    # route methods real without inventing preview behavior in its controlled transport.
    preview_start = core.index("  enum NativePreviewResult", fields_start, fields_end)
    preview_end = core.index("  private struct NativeCompatibilityRestore", preview_start, fields_end)
    methods = ["advancePlaybackRoute", "applyNativeViewport", "cancelNativeLoopRequests", "requireMPVCompatibility", "retireNativePlayback", "stop", "shutdown", "open", "openMediaURLs",
               "cancelPendingPermanentRotation", "resetPermanentRotationMedia", "ownsPermanentRotationRequest"]
    bridge = (ROOT / "iina/VideoTools/VideoToolsPlayerBridge.swift").read_text()
    model = bridge[bridge.index("struct VideoToolsViewport:"):bridge.index("struct VideoToolsPlayerSnapshot")]
    generated = "import Cocoa\n" + model + "\nfinal class PlayerCore: CoreBoundary {\n"
    generated += core[gate_start:gate_end] + "\n" + core[fields_start:preview_start] + core[preview_end:fields_end]
    rotation_start = core.index("  private var permanentRotationIntent")
    rotation_end = core.index("\n  /// Both window shortcuts", rotation_start)
    generated += core[rotation_start:rotation_end] + "\n"
    pending_start = core.index("  var nativeInitialPlaybackPending: Bool {")
    pending_end = core.index("\n  }", pending_start) + len("\n  }")
    generated += "\n" + core[pending_start:pending_end] + "\n"
    bodies = {name: method(core, name) for name in methods}
    if args.negative_control:
        guard = "    guard !nativeTerminationRequested, info.state != .shuttingDown, info.state != .shutDown else { return }\n"
        if guard not in bodies["stop"]:
            raise RuntimeError("Terminal-priority negative-control boundary changed")
        bodies["stop"] = bodies["stop"].replace(guard, "", 1)
    if args.capture_negative_control:
        guard = "          if self.nativeReady {"
        if guard not in bodies["requireMPVCompatibility"]:
            raise RuntimeError("Precise capture negative-control boundary changed")
        bodies["requireMPVCompatibility"] = bodies["requireMPVCompatibility"].replace(guard, "          if false {", 1)
    opening = method(core, "openMainWindow")
    boundary = '\n    advancePlaybackRoute(acceptsMPV: true)\n    log("Opening '
    if boundary not in opening:
        raise RuntimeError("Legacy open boundary changed")
    # Keep the production arbitration; the legacy UI/render/load side effects
    # are an explicit recording boundary, not a claim of full AppKit rendering.
    opening = opening[:opening.index(boundary)] + """
    advancePlaybackRoute(acceptsMPV: true)
    completeLegacyOpen(url: url, allowNative: allowNative)
  }
"""
    generated += "\n".join(bodies.values()) + "\n" + opening + "\n}\n"
    generated = generated.replace("private ", "")
    state_start = info.index("  var state: PlayerState = .idle {")
    state_end = info.index("  var isSeeking:", state_start)
    generated += "\nfinal class CoreInfo: CoreInfoBoundary {\n" + info[state_start:state_end] + "\n}\n"
    with tempfile.TemporaryDirectory(prefix="chengying-native-core-") as directory:
        work = Path(directory)
        production = work / "Production.swift"
        production.write_text(generated)
        executable = work / "NativeCoreTests"
        command = ["xcrun", "swiftc", "-warnings-as-errors", "-o", str(executable)]
        if args.sanitize:
            command.append("-sanitize=" + args.sanitize)
        command += [str(ROOT / path) for path in ["iina/Atomic.swift", "iina/Lock.swift", "iina/PlayerState.swift",
                    "iina/MPVCommand.swift", "iina/MPVOption.swift", "iina/VideoTools/VideoToolsShortcuts.swift", "iina/VideoTools/VideoToolsRotationIntent.swift", "Tools/NativePlayerCoreTests/Boundary.swift",
                    "Tools/NativePlayerCoreTests/main.swift"]]
        subprocess.run(command + [str(production)], check=True, timeout=90)
        if args.negative_control or args.capture_negative_control:
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=25)
            expected = ("FAIL: A ready preroll never silently restores the file at zero" if args.capture_negative_control else
                        "FAIL: Shutdown intent cannot be replaced by a later window-close stop")
            if result.returncode != 1 or expected not in result.stderr:
                raise RuntimeError("Negative control missed the expected shutdown invariant: " + result.stderr)
            print("PASS: Negative control reproduces the expected lifecycle invariant failure")
        else:
            subprocess.run([str(executable)], check=True, timeout=25)


if __name__ == "__main__":
    main()
