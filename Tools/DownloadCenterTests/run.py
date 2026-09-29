"""Run real WebKit fixtures inside a precisely retired disposable app workspace."""

import fcntl
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from other.test_app_workspace import CleanupError, TestAppWorkspace, _record_failure


def interrupted(_number, _frame):
    raise KeyboardInterrupt("Native WebKit verification interrupted")


def close_fixture_gate(gate, workspace, *, timeout=15):
    """Wait for this run's shared child locks, then forbid delayed child startup."""
    try:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(gate, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise CleanupError("Native fixture shutdown could not be confirmed.") from None
                time.sleep(0.05)
        # An already running fixture holds a shared lock until process exit. A
        # delayed interpreter can only obtain its shared lock after this write,
        # then sees the closed gate and exits before starting any fixture work.
        gate.seek(0)
        gate.truncate()
        gate.write("closed\n")
        gate.flush()
    except BaseException:
        _record_failure(workspace.path, "Native fixture process cleanup was not confirmed.",
                        expected_identity=workspace.identity)
        raise


def main():
    if sys.version_info < (3, 11):
        raise SystemExit("Native WebKit verification requires Python 3.11 or newer.")
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, interrupted)
    sources = [str(ROOT / source) for source in (
        "iina/Updates/UpdateWorkAdmission.swift",
        "iina/ChengYingStyle.swift",
        "iina/ImageViewer/ImageFileSupport.swift",
        "iina/DownloadCenter/DownloadCenterModels.swift",
        "iina/DownloadCenter/DownloadCenterService.swift",
        "iina/DownloadCenter/DownloadCenterWindowController.swift",
        "Tools/DownloadCenterTests/Stubs.swift",
    )]
    fixture_python = subprocess.check_output(
        ["xcrun", "--find", "python3"], text=True, timeout=30,
    ).strip()
    environment = dict(os.environ)
    environment["PATH"] = str(Path(fixture_python).parent) + os.pathsep + environment.get("PATH", "")
    workspace = TestAppWorkspace(prefix="download-center-")
    try:
        with workspace as directory:
            print(f"Native WebKit test workspace: {directory}", flush=True)
            gate_path = Path(directory) / ".native-fixture-process-gate"
            environment["CHENGYING_WK_PROCESS_GUARD"] = str(gate_path)
            with gate_path.open("x+", encoding="ascii") as gate:
                gate.write("open\n")
                gate.flush()
                try:
                    run_app_suite(directory, sources, environment)
                finally:
                    close_fixture_gate(gate, workspace)
            print("Native WebKit fixture processes drained; delayed startup disabled.", flush=True)
    finally:
        if workspace.cleaned:
            print(f"Native WebKit test workspace unregistered and removed: {workspace.name}", flush=True)


def run_app_suite(directory, sources, environment):
    bundle = Path(directory) / "DownloadCenterTests.app/Contents"
    executable = bundle / "MacOS/DownloadCenterTests"
    executable.parent.mkdir(parents=True)
    shutil.copy2(ROOT / "Tools/DownloadCenterTests/Info.plist", bundle / "Info.plist")
    for language in ("en", "zh-Hans"):
        resources = bundle / "Resources" / f"{language}.lproj"
        resources.mkdir(parents=True)
        shutil.copy2(ROOT / "iina" / f"{language}.lproj/DownloadCenter.strings", resources)
    subprocess.run(
        ["xcrun", "swiftc", "-target", "x86_64-apple-macos10.15", "-typecheck", *sources],
        check=True, env=environment, timeout=180,
    )
    subprocess.run(
        ["xcrun", "swiftc", "-o", str(executable), *sources,
         str(ROOT / "Tools/DownloadCenterTests/main.swift")],
        check=True, env=environment, timeout=180,
    )
    for language in ("en", "zh-Hans"):
        subprocess.run(
            [str(executable), str(ROOT / "Tools/DownloadCenterTests/helper_fixture.py"),
             directory, "-AppleLanguages", f"({language})"],
            check=True, env=environment, timeout=240,
        )


if __name__ == "__main__":
    main()
