#!/usr/bin/env python3
"""Compile production event dispatch and inject delayed events without user media."""
import argparse
import contextlib
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
COMPILED_SOURCES = ["iina/Atomic.swift", "iina/Lock.swift", "iina/MPVOption.swift",
    "iina/MPVProperty.swift", "iina/MPVCommand.swift", "iina/MPVHook.swift", "iina/MPVNode.swift",
    "iina/PlaybackBackend/NativePlaybackQueue.swift", "iina/PlaybackBackend/MPVQueueInstaller.swift",
    "Tools/PlaybackBackendRoutingTests/Boundary.swift", "Tools/PlaybackBackendRoutingTests/main.swift",
    "Tools/PlaybackBackendRoutingTests/QueueResume.swift"]


def generated_digests(work):
    return {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in work.iterdir()
            if path.suffix in {".swift", ".wav", ".mp4"}}


def section(text, start, end):
    if text.count(start) != 1:
        raise RuntimeError(f"Production boundary changed: {start}")
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


@contextlib.contextmanager
def evidence_directory(sources):
    work = Path(tempfile.mkdtemp(prefix="native-mpv-event-bridge.", dir=ROOT / "build"))
    before = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
    (work / "source-before.json").write_text(json.dumps(before, indent=2) + "\n")
    print("Artifacts: " + str(work), flush=True)
    completed = False
    try:
        yield work
        completed = True
    finally:
        after = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
        (work / "source-after.json").write_text(json.dumps(after, indent=2) + "\n")
        generated = generated_digests(work)
        (work / "generated-after.json").write_text(json.dumps(generated, indent=2) + "\n")
        if completed and before != after:
            raise RuntimeError("Production input changed during event bridge verification")
        manifest = work / "generated-before.json"
        if completed and (not manifest.is_file() or json.loads(manifest.read_text()) != generated):
            raise RuntimeError("Generated input changed during event bridge verification")


def extract_production(args):
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
    generated = "import Cocoa\nimport QuartzCore\n" + "final class MPVController: RoutingControllerFixture, MPVQueueInstallationBackend {\n"
    generated += route + properties + commands + setters + hook + events + "\n}\n"
    generated = generated.replace("private ", "")
    idle = section(core, "  func idleActiveChanged() {", "  func mediaTitleChanged()")
    player = "import Foundation\nfinal class PlayerCore: RoutingPlayerFixture {\n" + gate.replace("private ", "") + idle + "\n}\n"
    if args.negative_control == "epoch":
        original = "$0.acceptsMPV && $0.revision == revision"
        if original not in player:
            raise RuntimeError("Epoch negative-control boundary changed")
        player = player.replace(original, "$0.acceptsMPV && ($0.revision == revision || true)")
    elif args.negative_control == "first-start":
        if "awaitingFirstRoutedStart = true" not in generated:
            raise RuntimeError("First-start negative-control boundary changed")
        generated = generated.replace("awaitingFirstRoutedStart = true", "awaitingFirstRoutedStart = false")
    elif args.negative_control == "queue-owner":
        original = "guard let self, self.nativeQueueEventOwner == owner else { return }"
        if generated.count(original) != 1:
            raise RuntimeError("Queue owner negative-control boundary changed")
        generated = generated.replace(original, "guard let self else { return }")
    elif args.negative_control == "queue-start-context":
        original = "nativeQueueReaderOwner = owner\n      nativeQueueStartedEntry = nil"
        if generated.count(original) != 1:
            raise RuntimeError("Queue START negative-control boundary changed")
        generated = generated.replace(original, "nativeQueueReaderOwner = owner")
    elif args.negative_control == "queue-stop-completion":
        original = "self?.pollCancelledNativeQueueStop(owner: owner, revision: revision, deadline: deadline)"
        if generated.count(original) != 3:
            raise RuntimeError("Queue stop completion negative-control boundary changed")
        generated = generated.replace(original, "_ = (self, owner, revision, deadline)", 1)
    elif args.negative_control == "queue-stop-current":
        original = "snapshot.entries.allSatisfy({ !$0.current && !$0.playing })"
        if generated.count(original) != 1:
            raise RuntimeError("Queue selected-entry stop boundary changed")
        generated = generated.replace(original, "true")
    elif args.negative_control == "queue-stop-route":
        original = "player.acceptsMPVEventRevision(revision), player.info.state == .stopping"
        if generated.count(original) != 3:
            raise RuntimeError("Queue stop route boundary changed")
        generated = generated.replace(original, "player.info.state == .stopping")
    elif args.negative_control == "queue-stop-event-gate":
        original = "if nativeQueueStopEventOwner != nil {"
        if generated.count(original) != 1:
            raise RuntimeError("Queue stop event gate boundary changed")
        generated = generated.replace(original, "if false {")
        original = "let routeRevision = nativeQueueStopEventOwner == nil ? player.captureMPVEventRevision() : nil"
        if generated.count(original) != 1:
            raise RuntimeError("Queue stop control event gate boundary changed")
        generated = generated.replace(original, "let routeRevision = player.captureMPVEventRevision()")
    elif args.negative_control == "queue-stop-keep-list":
        original = 'queueCommand(["stop", "keep-playlist"])'
        if generated.count(original) != 1:
            raise RuntimeError("Queue retained-list stop boundary changed")
        generated = generated.replace(original, 'queueCommand(["stop"])')
    elif args.negative_control == "queue-stop-list-owner":
        original = "snapshot.entries.map(\\.id) == entryIDs else {"
        if generated.count(original) != 1:
            raise RuntimeError("Queue stop list ownership boundary changed")
        generated = generated.replace(original, "(snapshot.entries.map(\\.id) == entryIDs || true) else {")
    elif args.negative_control == "queue-stop-reader-drain":
        original = """readEvents()
      queue.async { [weak self] in
        DispatchQueue.main.async {
          self?.finishCancelledNativeQueueStop(owner: owner, revision: revision, deadline: deadline)
        }
      }"""
        if generated.count(original) != 1:
            raise RuntimeError("Queue stop reader drain boundary changed")
        generated = generated.replace(original,
            "finishCancelledNativeQueueStop(owner: owner, revision: revision, deadline: deadline)")
    elif args.negative_control == "queue-stop-preparation":
        original = "nativeQueueStopEventOwner = owner"
        if generated.count(original) != 2:
            raise RuntimeError("Queue stop preparation boundary changed")
        generated = generated.replace(original, "_ = owner", 1)
    elif args.negative_control == "pending-volume":
        original = "let volume = player.pendingPlaybackVolume ?? data"
        if generated.count(original) != 1:
            raise RuntimeError("Pending restore volume boundary changed")
        generated = generated.replace(original, "let volume = data")
    elif args.negative_control == "initial-idle-recording":
        original = '''if let name = mpv_event_name(event.pointee.event_id), String(cString: name) == "idle" {
      hasReachedInitialQueueIdle = true
    }'''
        if generated.count(original) != 1:
            raise RuntimeError("Initial idle recording boundary changed")
        generated = generated.replace(original, "// Negative control: discard actual startup IDLE evidence.")
    if args.negative_control == "queue-resume-restart":
        original = "if let entryID = nativeQueueStartedEntry { forwarded = .playbackRestart(entryID: entryID) }"
        if generated.count(original) != 1:
            raise RuntimeError("Queue resume restart boundary changed")
        generated = generated.replace(original, "if nativeQueueStartedEntry != nil { forwarded = nil }", 1)
    return generated, player


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sanitize", choices=["address", "thread"])
    parser.add_argument("--initial-idle-only", action="store_true")
    parser.add_argument("--queue-resume-only", action="store_true")
    parser.add_argument("--negative-control", choices=["epoch", "first-start", "queue-owner", "queue-start-context",
                                                     "queue-stop-completion", "queue-stop-current", "queue-stop-route",
                                                     "queue-stop-event-gate", "queue-stop-keep-list", "queue-stop-list-owner",
                                                     "queue-stop-reader-drain", "queue-stop-preparation", "pending-volume",
                                                     "initial-idle-recording", "queue-resume-restart"])
    args = parser.parse_args()
    if args.initial_idle_only and args.negative_control not in {None, "initial-idle-recording"}:
        parser.error("The initial idle scope cannot run another negative control")
    if args.queue_resume_only and (args.initial_idle_only or args.negative_control not in {None, "queue-resume-restart"}):
        parser.error("The queue resume scope cannot run another scope or control")
    sources = [ROOT / name for name in COMPILED_SOURCES + ["iina/MPVController.swift", "iina/PlayerCore.swift",
        "Tools/PlaybackBackendRoutingTests/run.py", "deps/include/mpv/client.h", "iina/IINA-Bridging-Header.h"]]
    sources += sorted((ROOT / "deps/lib").glob("*.dylib"))
    with evidence_directory(sources) as work:
        generated, player = extract_production(args)
        media = work / "synthetic.wav"
        subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                        "-i", "anullsrc=r=8000:cl=mono", "-t", "0.05", str(media)], check=True, timeout=20)
        video = work / "queue.mp4"
        subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                        "-i", "color=c=blue:s=160x96:r=20:d=3", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        str(video)], check=True, timeout=20)
        (work / "Production.swift").write_text(generated)
        (work / "Player.swift").write_text(player)
        (work / "generated-before.json").write_text(json.dumps(generated_digests(work), indent=2) + "\n")
        executable = work / "RoutingTests"
        production_header = (ROOT / "iina/IINA-Bridging-Header.h").read_text()
        if production_header.splitlines()[0] != "#define MPV_ENABLE_DEPRECATED 0":
            raise RuntimeError("Production MPV deprecation configuration changed")
        command = ["xcrun", "swiftc", "-warnings-as-errors", "-o", str(executable),
                   "-Xcc", "-DMPV_ENABLE_DEPRECATED=0",
                   "-import-objc-header", str(ROOT / "deps/include/mpv/client.h")]
        if args.sanitize:
            command += ["-sanitize=" + args.sanitize]
        command += [str(ROOT / path) for path in COMPILED_SOURCES]
        command += [str(work / "Production.swift"), str(work / "Player.swift"),
                    str(ROOT / "deps/lib/libmpv.2.dylib"), "-Xlinker", "-rpath", "-Xlinker", str(ROOT / "deps/lib")]
        (work / "compile-command.json").write_text(json.dumps(command, indent=2) + "\n")
        compilation = subprocess.run(command, capture_output=True, text=True, timeout=90)
        (work / "compile-stdout.log").write_text(compilation.stdout)
        (work / "compile-stderr.log").write_text(compilation.stderr)
        (work / "compile-exit-status.txt").write_text(str(compilation.returncode) + "\n")
        if compilation.returncode:
            print(compilation.stderr, end="")
        compilation.check_returncode()
        initial_idle_only = args.initial_idle_only or args.negative_control == "initial-idle-recording"
        queue_resume_only = args.queue_resume_only or args.negative_control == "queue-resume-restart"
        runtime = [str(executable), str(media), str(video)]
        if initial_idle_only:
            runtime.append("initial-idle-only")
        if queue_resume_only:
            runtime.append("queue-resume-only")
        result = subprocess.run(runtime, capture_output=True, text=True, timeout=35)
        (work / "stdout.log").write_text(result.stdout)
        (work / "stderr.log").write_text(result.stderr)
        (work / "exit-status.txt").write_text(str(result.returncode) + "\n")
        print(result.stdout, end="")
        print(result.stderr, end="")
        if "WARNING: ThreadSanitizer" in result.stderr or "ERROR: AddressSanitizer" in result.stderr:
            raise RuntimeError("Event bridge emitted a sanitizer diagnostic")
        if queue_resume_only:
            lines = (result.stdout + result.stderr).splitlines()
            failures = [line for line in lines if line.startswith("FAIL:")]
            expected = []
            if args.negative_control:
                for label in ["reader-before-main", "restart-before-loaded-delivery"]:
                    expected += [f"FAIL: {label}: {suffix}" for suffix in [
                        "exact owned initial restart completes one verified receipt",
                        "restart receipt identifies selected duplicate entry",
                        "production reader forwards initial restart exactly once",
                        "duplicate restart cannot deliver a second receipt"]]
            count = 28
            if (result.returncode != (1 if expected else 0)
                    or [line for line in lines if line.startswith("CASE:")] != ["CASE: queue-resume"]
                    or [line for line in lines if line.startswith("Queue resume bridge:")] != [f"Queue resume bridge: {count} checks, {len(expected)} failures"]
                    or failures != expected
                    or sum(line.startswith(("PASS:", "FAIL:")) for line in lines) != count):
                raise RuntimeError("Queue resume scope did not produce its complete exact result")
            print("PASS: Exact queue resume scope accepted")
            return
        if initial_idle_only:
            expected = "FAIL: Production reader records actual IDLE before the native presentation gate"
            expected_failures = 1 if args.negative_control else 0
            failures = [line for line in (result.stdout + result.stderr).splitlines() if line.startswith("FAIL:")]
            summaries = [line for line in result.stdout.splitlines() if line.startswith("Initial idle bridge:")]
            cases = [line for line in result.stdout.splitlines() if line.startswith("CASE:")]
            passes = [line for line in result.stdout.splitlines() if line.startswith("PASS:")]
            if (result.returncode != expected_failures or cases != ["CASE: initial-idle"]
                    or summaries != [f"Initial idle bridge: 7 checks, {expected_failures} failures"]
                    or failures != ([expected] if expected_failures else [])
                    or len(passes) + len(failures) != 7):
                raise RuntimeError("Initial idle scope did not produce its complete exact result")
            print("PASS: Exact initial idle scope accepted")
            return
        if args.negative_control:
            expected = {"epoch": "Old queued callbacks cannot alias a new MPV epoch",
                        "first-start": "First-load barrier rejects startup properties before START_FILE",
                        "queue-owner": "Queued old envelopes cannot borrow a new installation owner",
                        "queue-start-context": "A new owner cannot inherit the previous START context",
                        "queue-stop-completion": "Pre-START cancellation reaches actual idle and releases pending reopen",
                        "queue-stop-current": "Selected before-START entry prevents premature stop acknowledgement",
                        "queue-stop-route": "A queued stop acknowledgement cannot cross playback route revisions",
                        "queue-stop-event-gate": "Special stop suppresses premature ordinary idle and media callbacks after START",
                        "queue-stop-keep-list": "Repeated owned stop preserves the retained prefix while refreshing its route",
                        "queue-stop-list-owner": "Cancelled stop cannot clear foreign entries or falsely acknowledge idle",
                        "queue-stop-reader-drain": "Actual idle cannot reopen until the old reader backlog is drained",
                        "queue-stop-preparation": "Special stop suppresses premature ordinary idle and media callbacks after START",
                        "pending-volume": "Pending restore volume is resolved at delivery for info UI and OSD",
                        "initial-idle-recording": "Production reader records actual IDLE before the native presentation gate"}[args.negative_control]
            if result.returncode != 1 or "FAIL: " + expected not in result.stderr:
                raise RuntimeError("Negative control did not fail at the intended invariant: " + result.stderr)
            print("PASS: Negative control rejected: " + expected)
        else:
            result.check_returncode()


if __name__ == "__main__":
    main()
