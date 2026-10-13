"""Bounded AppKit preference routing checks; never launch the installed app."""
import argparse
import hashlib
from pathlib import Path
import os
import re
import signal
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--negative", choices=["direct-observer", "drop-ui-guard", "drop-inventory-guard", "drop-shutdown-guard", "retry-native"])
parser.add_argument("--sanitizer", choices=["address", "thread"])
parser.add_argument("--build-only", action="store_true")
args = parser.parse_args()
work = Path(tempfile.mkdtemp(prefix="native-audio-preference.", dir=root / "build"))
print("Artifacts:", work, flush=True)
inputs = [root / f"iina/{name}" for name in ("PlayerCore.swift", "MPVController.swift", "PrefCodecViewController.swift", "MPVAudioDevice.swift", "Atomic.swift", "Lock.swift")]
inputs += [root / "Tools/NativeAudioPreferenceTests" / name for name in
           ("Boundary.swift", "main.swift", "prepare.py", "run.py", "verify_negative.py")]
def snapshot(paths): return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
before = snapshot(inputs)
def record(path, data): path.write_text("".join(f"{value}  {name}\n" for name, value in data.items()))
record(work / "source-before.sha256", before)
status = 1
generated = {}
try:
    subprocess.run(["python3", "-B", "Tools/NativeAudioPreferenceTests/prepare.py", str(work), args.negative or ""], cwd=root, check=True)
    generated = snapshot([work / "Extracted.swift"])
    record(work / "generated.sha256", generated)
    flags = ["-sanitize=" + args.sanitizer] if args.sanitizer else []
    with (work / "compile.log").open("w") as log:
        compiled = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-target", "arm64-apple-macos12", *flags,
            str(work / "Extracted.swift"), "iina/MPVAudioDevice.swift", "iina/Atomic.swift", "iina/Lock.swift", "Tools/NativeAudioPreferenceTests/Boundary.swift",
            "Tools/NativeAudioPreferenceTests/main.swift", "-framework", "AppKit", "-o", str(work / "test")],
            cwd=root, stdout=log, stderr=subprocess.STDOUT, timeout=60)
    (work / "compile-exit.txt").write_text(str(compiled.returncode) + "\n")
    if compiled.returncode: raise RuntimeError("Compilation failed")
    generated.update(snapshot([work / "test"]))
    record(work / "generated.sha256", generated)
    if args.build_only:
        status = 0
    else:
        with (work / "results.log").open("w") as log:
            environment = os.environ.copy()
            environment["ASAN_OPTIONS"] = "halt_on_error=1"
            environment["TSAN_OPTIONS"] = "halt_on_error=1"
            child = subprocess.Popen([str(work / "test")], stdout=log, stderr=subprocess.STDOUT,
                                     start_new_session=True, env=environment)
            try: status = child.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL); child.wait(); raise RuntimeError("Preference fixture timed out")
        (work / "child-exit.txt").write_text(str(status) + "\n")
        result = (work / "results.log").read_text()
        print(result)
        if re.search(r"ERROR: AddressSanitizer|WARNING: ThreadSanitizer|SUMMARY: (?:AddressSanitizer|ThreadSanitizer)|Sanitizer:DEADLYSIGNAL|runtime error:", result):
            status = 1
        else:
            with (work / "result-validation.log").open("w") as log:
                verified = subprocess.run(["python3", "-B", "Tools/NativeAudioPreferenceTests/verify_negative.py", args.negative or "normal", str(work)], cwd=root, stdout=log, stderr=subprocess.STDOUT)
            status = verified.returncode
            print((work / "result-validation.log").read_text())
finally:
    after = snapshot(inputs)
    record(work / "source-after.sha256", after)
    identities = before == after and generated == snapshot([Path(p) for p in generated])
    (work / "identity-validation.txt").write_text(str(identities) + "\n")
    if not identities: status = 1
    (work / "exit-status.txt").write_text(str(status) + "\n")
raise SystemExit(status)
