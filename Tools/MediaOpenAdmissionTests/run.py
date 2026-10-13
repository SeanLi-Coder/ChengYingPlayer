#!/usr/bin/env python3
"""Exercise extracted media-open and matcher code without AppKit or user media."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def method(source, signature):
    start = "  " + signature
    if source.count(start) != 1:
        raise RuntimeError(f"Ambiguous production method: {signature}")
    begin = source.index(start)
    end = source.index("\n  }", begin) + len("\n  }")
    return source[begin:end].replace("  private func ", "  func ", 1)


def main():
    parser = argparse.ArgumentParser()
    negative = parser.add_mutually_exclusive_group()
    negative.add_argument("--negative-control", help="Require the old open method to fail the cancellation barrier")
    negative.add_argument("--negative-late-cancel", action="store_true", help="Publish cancellation only after acquiring the batch lock")
    negative.add_argument("--negative-matcher", help="Require the old matcher to fail its post-append cancellation check")
    negative.add_argument("--negative-post-append", action="store_true", help="Remove only the post-append cancellation check")
    parser.add_argument("--sanitize", choices=["thread", "address"])
    args = parser.parse_args()
    (ROOT / "build").mkdir(exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="media-open-admission.", dir=ROOT / "build"))
    print(f"Artifacts: {evidence}", flush=True)
    paths = ["iina/PlayerCore.swift", "iina/AutoFileMatcher.swift", "iina/Atomic.swift", "iina/Lock.swift",
             "iina/PlaylistPlaybackPolicy.swift", "Tools/MediaOpenAdmissionTests/run.py",
             "Tools/MediaOpenAdmissionTests/Boundary.swift", "Tools/MediaOpenAdmissionTests/main.swift"]
    def fingerprints():
        return {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in paths}
    before = fingerprints()
    (evidence / "source-before.json").write_text(json.dumps(before, indent=2) + "\n")
    succeeded = False
    try:
        run(args, evidence)
        succeeded = True
    finally:
        after = fingerprints()
        (evidence / "source-after.json").write_text(json.dumps(after, indent=2) + "\n")
        unchanged = before == after
        (evidence / "exit-status.txt").write_text("0\n" if succeeded and unchanged else "1\n")
        if not unchanged:
            raise RuntimeError("Production or test source changed during verification")


def run(args, evidence):
    core = (ROOT / "iina/PlayerCore.swift").read_text()
    matcher = (ROOT / "iina/AutoFileMatcher.swift").read_text()
    if args.negative_control:
        core = subprocess.check_output(
            ["git", "show", f"{args.negative_control}:iina/PlayerCore.swift"], cwd=ROOT,
            text=True, timeout=15)
    if args.negative_matcher:
        matcher = subprocess.check_output(
            ["git", "show", f"{args.negative_matcher}:iina/AutoFileMatcher.swift"], cwd=ROOT,
            text=True, timeout=15)
    if args.negative_late_cancel:
        ticket = "    let openTicket = $backgroundQueueTicket.withLock { ticket in\n      ticket += 1\n      return ticket\n    }\n"
        before = ticket + "    playlistMutationLock.lock()\n    defer { playlistMutationLock.unlock() }\n"
        after = "    playlistMutationLock.lock()\n    defer { playlistMutationLock.unlock() }\n" + ticket
        if core.count(before) != 1:
            raise RuntimeError("Pre-lock cancellation boundary changed")
        core = core.replace(before, after, 1)
    if args.negative_post_append:
        marker = "        // Opening another file can cancel this batch while append is in flight.\n"
        marker += "        // Leave the lock before a stale follow-up move delays that newer open.\n        try checkTicket()\n"
        if matcher.count(marker) != 1:
            raise RuntimeError("Post-append mutation boundary changed")
        matcher = matcher.replace(marker, "", 1)
    generated = "import Foundation\nextension PlayerCore {\n" + method(
        core, "func openMediaURLs(_ urls: [URL], shouldAutoLoad autoLoad: Bool = true) -> Int?")
    generated += "\n" + method(core, "func checkTicket(_ ticket: Int) throws") + "\n}\n"
    generated += "extension AutoFileMatcher {\n" + method(
        matcher, "private func addFilesToPlaylist() throws") + "\n}\n"
    (evidence / "generated-source.sha256").write_text(hashlib.sha256(generated.encode()).hexdigest() + "\n")
    with tempfile.TemporaryDirectory(prefix="chengying-open-admission-") as directory:
        work = Path(directory)
        extracted = work / "Production.swift"
        extracted.write_text(generated)
        executable = work / "MediaOpenAdmissionTests"
        command = ["xcrun", "swiftc", "-o", str(executable)]
        if args.sanitize:
            command += ["-sanitize=" + args.sanitize, "-g"]
        command += [str(ROOT / path) for path in [
            "iina/Atomic.swift", "iina/Lock.swift", "iina/PlaylistPlaybackPolicy.swift",
            "Tools/MediaOpenAdmissionTests/Boundary.swift"]]
        command += [str(extracted), str(ROOT / "Tools/MediaOpenAdmissionTests/main.swift")]
        compile_result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        (evidence / "compile.log").write_text(compile_result.stdout + compile_result.stderr)
        print(compile_result.stdout, end="")
        print(compile_result.stderr, end="")
        compile_result.check_returncode()
        result = subprocess.run([str(executable), str(work)] +
                                (["--negative-control"] if args.negative_control or args.negative_late_cancel else []),
                                capture_output=True, text=True, timeout=30)
        print(result.stdout, end="")
        print(result.stderr, end="")
        (evidence / "test.log").write_text(result.stdout + result.stderr)
        (evidence / "test-exit-status.txt").write_text(str(result.returncode) + "\n")
        if args.negative_control or args.negative_late_cancel:
            if result.returncode != 1 or "accepted open must cancel the old matcher before waiting for its lock" not in result.stderr:
                raise RuntimeError("The old production method did not fail at the intended cancellation barrier")
            print("PASS: Old production open failed at the expected cancellation barrier")
        elif args.negative_matcher or args.negative_post_append:
            if result.returncode != 1 or "A cancelled old append must not be followed by a playlist move" not in result.stderr:
                raise RuntimeError("The old matcher did not fail at the intended post-append boundary")
            print("PASS: Old production matcher failed at the expected post-append boundary")
        elif result.returncode:
            raise subprocess.CalledProcessError(result.returncode, str(executable))


if __name__ == "__main__":
    main()
