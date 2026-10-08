#!/usr/bin/env python3
"""Exercise the production rendering layer with real synchronous libmpv close calls."""
import argparse
import hashlib
import json
import os
import plistlib
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from other.test_app_workspace import CleanupError, TestAppWorkspace


def validate_execution_environment(environment, *, diagnostic_mode):
    if environment.get("CLOSE_TEST_GL_PASS_DIAGNOSTICS") == "1" and not diagnostic_mode:
        raise ValueError("CLOSE_TEST_GL_PASS_DIAGNOSTICS=1 requires --failure-diagnostics")
    if "CLOSE_TEST_MPE_CONTROL" in environment:
        raise ValueError("Unset CLOSE_TEST_MPE_CONTROL; only --mpe-diagnostic-matrix selects MPE states")
    loader_overrides = sorted(name for name in environment
                              if name.startswith("DYLD_") or name == "LD_LIBRARY_PATH")
    if loader_overrides:
        raise ValueError("Unset inherited loader variables before playback verification: " + ", ".join(loader_overrides))


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--priority", action="store_true", help="Check deterministic recursive render lock scheduling")
parser.add_argument("--layer-ref", help="Use an existing commit's ViewLayer for a negative control")
parser.add_argument("--deps-dir", type=Path, default=ROOT / "deps", help="Playback dependency tree supplying libmpv, headers and runtime libraries")
parser.add_argument("--failure-diagnostics", type=Path, help="Preserve bounded synthetic failure logs and screenshots")
parser.add_argument("--diagnostic-attempts", type=int, default=1, choices=range(1, 4), help="Run this many fixed attempts using one compiled diagnostic executable")
parser.add_argument("--mpe-diagnostic-matrix", action="store_true", help="Run one fixed default/disabled/default/disabled MPE diagnostic matrix")
args = parser.parse_args()
if args.diagnostic_attempts != 1 and args.failure_diagnostics is None:
    parser.error("Multiple diagnostic attempts require --failure-diagnostics")
if args.failure_diagnostics is not None and args.priority:
    parser.error("Failure screenshots cannot be combined with --priority")
if args.mpe_diagnostic_matrix and (args.failure_diagnostics is None or args.diagnostic_attempts != 1):
    parser.error("MPE matrix requires --failure-diagnostics and cannot use --diagnostic-attempts")
execution_environment = dict(os.environ)
try:
    validate_execution_environment(execution_environment, diagnostic_mode=args.failure_diagnostics is not None)
except ValueError as error:
    parser.error(str(error))
playback_deps = args.deps_dir.expanduser().resolve()
playback_library = playback_deps / "lib/libmpv.2.dylib"
if not args.priority and (not playback_library.is_file() or not (playback_deps / "include").is_dir()):
    parser.error("Playback dependencies must contain lib/libmpv.2.dylib and include")
playback_identity = None
if not args.priority:
    patch_record = playback_deps / "playback-build-record/patches.tsv"
    patch_ids = [line.split("\t", 1)[0] for line in patch_record.read_text().splitlines() if line.strip()] if patch_record.is_file() else None
    playback_identity = {"deps_dir": str(playback_deps), "library_path": str(playback_library),
                         "library_sha256": hashlib.sha256(playback_library.read_bytes()).hexdigest(),
                         "patch_ids": patch_ids, "patch_record_present": patch_record.is_file()}
reference = None
if args.layer_ref:
    reference = subprocess.check_output([
        "git", "rev-parse", "--verify", "--end-of-options", f"{args.layer_ref}^{{commit}}"
    ], cwd=ROOT, text=True, timeout=30, env=execution_environment).strip()

report = None
report_dir = None
return_code = 1


def contains_cleanup_error(error):
    return isinstance(error, CleanupError) or any(
        contains_cleanup_error(item) for item in getattr(error, "exceptions", ())
    )


@contextmanager
def verified_workspace():
    global return_code
    try:
        with TestAppWorkspace(prefix="player-close-") as directory:
            yield directory
    except BaseException as error:
        if not contains_cleanup_error(error):
            raise
        return_code = 1
        if report is not None:
            report["passed"] = False
            report["cleanup"] = {"status": "needs_attention", "workspace_retained": True,
                                 "reason": "Test workspace cleanup did not complete safely."}
            (report_dir / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
        print("CLEANUP: needs_attention; owned workspace retained for inspection", flush=True)
    else:
        if report is not None:
            report["cleanup"] = {"status": "completed", "workspace_retained": False}
            report["passed"] = report["execution_passed"]
            (report_dir / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
        print("CLEANUP: owned test app unregistered and disposable workspace retired", flush=True)


with verified_workspace() as directory:
    work = Path(directory)
    layer = ROOT / "iina/ViewLayer.swift"
    if reference:
        layer = work / "ViewLayer.swift"
        layer.write_bytes(subprocess.check_output(["git", "show", f"{reference}:iina/ViewLayer.swift"],
                                                 cwd=ROOT, timeout=30, env=execution_environment))
    if args.priority:
        source = layer.read_text()
        marker = "private class MainThreadPriorityLock {"
        if source.count(marker) != 1:
            raise RuntimeError("The production priority lock extraction boundary changed")
        extracted = "import Cocoa\n" + source[source.index(marker):].replace(marker, "class MainThreadPriorityLock {", 1)
        if "func beforeUnlocking()" not in extracted:
            extracted += "\nextension MainThreadPriorityLock { func beforeUnlocking() {} }\n"
        lock_source = work / "Priority.swift"
        lock_source.write_text(extracted)
        binary = work / "PriorityTests"
        subprocess.run(["xcrun", "swiftc", "-o", str(binary), str(lock_source),
                        str(ROOT / "Tools/PlayerCloseTests/PriorityMain.swift")],
                       check=True, timeout=180, env=execution_environment)
        subprocess.run([str(binary)], timeout=10, check=True, env=execution_environment)
        print("PASS: priority scheduling regression")
        sys.exit(0)
    executable = work / "PlayerCloseTests.app/Contents/MacOS/PlayerCloseTests"
    executable.parent.mkdir(parents=True)
    (executable.parent.parent / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "io.chengying.tests.player-close",
        "CFBundleExecutable": executable.name,
        "CFBundleName": "PlayerCloseTests",
        "CFBundlePackageType": "APPL",
        "LSUIElement": True,
    }))
    media = work / "generated.mp4"
    subprocess.run([str(ROOT / "deps/executable/ffmpeg"), "-nostdin", "-hide_banner", "-loglevel", "error",
                    "-f", "lavfi", "-i", "testsrc2=size=3840x2160:rate=60", "-t", "10",
                    "-c:v", "libx264", "-preset", "ultrafast", str(media)],
                   check=True, timeout=120, env=execution_environment)
    sources = ["iina/Atomic.swift", "iina/Lock.swift", "iina/ReadWriteAtomic.swift",
               "iina/ReadWriteLock.swift", "iina/MPVOption.swift",
               "Tools/PlayerCloseTests/GLPassDiagnostics.swift",
               "Tools/PlayerCloseTests/Boundary.swift", "Tools/PlayerCloseTests/main.swift"]
    subprocess.run(["xcrun", "swiftc", "-suppress-warnings", "-o", str(executable),
                    *[str(ROOT / path) for path in sources],
                    str(layer),
                    "-import-objc-header", str(ROOT / "Tools/PlayerCloseTests/Bridge.h"),
                    "-I", str(playback_deps / "include"), str(playback_library),
                    "-Xlinker", "-rpath", "-Xlinker", str(playback_deps / "lib")],
                   check=True, timeout=180, env=execution_environment)
    if args.failure_diagnostics is None:
        result = subprocess.run([str(executable), str(media)], timeout=390, check=False, env=execution_environment)
        return_code = result.returncode if result.returncode >= 0 else 1
    else:
        report_dir = args.failure_diagnostics.resolve()
        report_dir.mkdir(parents=True, exist_ok=False)
        modes = ["default", "disabled", "default", "disabled"] if args.mpe_diagnostic_matrix else [None] * args.diagnostic_attempts
        report = {"diagnostic_only": True, "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
                  "playback_library": playback_identity,
                  "attempt_count": len(modes), "modes": modes, "control_valid": True,
                  "gl_pass_diagnostics": execution_environment.get("CLOSE_TEST_GL_PASS_DIAGNOSTICS") == "1",
                  "complete": False, "execution_passed": False, "passed": False,
                  "cleanup": {"status": "pending"}, "attempts": []}
        for number, mode in enumerate(modes, start=1):
            output_dir = report_dir / f"attempt-{number}"
            output_dir.mkdir()
            print(f"DIAGNOSTIC_START: attempt={number}, mode={mode}", flush=True)
            timed_out = False
            environment = dict(execution_environment)
            if mode is not None:
                environment["CLOSE_TEST_MPE_CONTROL"] = mode
            try:
                result = subprocess.run([str(executable), str(media), str(output_dir)], timeout=390,
                                        env=environment, check=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                output, native_code = result.stdout, result.returncode
            except subprocess.TimeoutExpired as error:
                output, native_code, timed_out = error.stdout or "", 124, True
                if isinstance(output, bytes):
                    output = output.decode("utf-8", errors="replace")
            (output_dir / "native.log").write_text(output)
            report["attempts"].append({"number": number, "mode": mode, "exit_code": native_code, "timed_out": timed_out,
                                       "passed": native_code == 0 and not timed_out,
                                       "outcome": [line for line in output.splitlines() if line.startswith(("MPE_CONTROL", "READY:", "PASS:", "FAILURE_DIAGNOSTICS:")) or "Precondition failed:" in line]})
            (report_dir / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
            print(f"DIAGNOSTIC_RESULT: attempt={number}, exit={native_code}, timed_out={timed_out}", flush=True)
            if args.mpe_diagnostic_matrix and (native_code == 78 or "MPE_CONTROL_INVALID:" in output):
                report["control_valid"] = False
                break
        report["complete"] = len(report["attempts"]) == len(modes)
        report["execution_passed"] = report["complete"] and report["control_valid"] and all(item["passed"] for item in report["attempts"])
        (report_dir / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
        return_code = 0 if report["execution_passed"] else 1
        print(f"DIAGNOSTIC_EXECUTION_SUMMARY: passed={report['execution_passed']}, cleanup=pending, report={report_dir}", flush=True)
if report is not None:
    print(f"DIAGNOSTIC_SUMMARY: passed={report['passed']}, cleanup={report['cleanup']['status']}, report={report_dir}", flush=True)
raise SystemExit(return_code)
