#!/usr/bin/env python3
"""Build and exercise the complete native playback App on a disposable CI Mac."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from other.test_app_workspace import TestAppWorkspace

REQUIRED_CHECKS = {
    "pristine_real_mpv_service", "native_first_frame_autoplay", "real_mainwindow_nib_outlets",
    "initial_volume_and_slider_zero", "native_window_has_no_compatibility_gl", "real_pause_menu_action",
    "paused_clock_stays_still", "real_volume_slider_action", "paused_seek_presents_green_frame",
    "rapid_replace_presents_latest_blue_frame", "retired_layer_detached", "replacement_resets_volume_and_slider",
    "real_window_close_retires_native_session", "embedded_subtitle_routes_to_real_compatibility",
    "compatibility_open_remains_silent", "second_pristine_real_mpv_service",
    "native_and_compatibility_ready_for_real_quit", "all_real_cores_shutdown_before_termination",
}


def validate_environment(environment):
    if (sys.platform != "darwin" or environment.get("CI") != "true" or
            environment.get("GITHUB_ACTIONS") != "true" or environment.get("RUNNER_ENVIRONMENT") != "github-hosted"):
        raise ValueError("Full App tests require a disposable GitHub Actions macOS runner.")
    if any(name.startswith("DYLD_") or name == "LD_LIBRARY_PATH" for name in environment):
        raise ValueError("Inherited dynamic loader overrides are not allowed.")


def validate_result(result, *, run_id, exit_code):
    if (exit_code != 0 or result.get("format") != 1 or result.get("run_id") != run_id or
            result.get("complete") is not True or result.get("passed") is not True):
        raise RuntimeError("Complete App execution or shutdown verification failed.")
    checks = result.get("checks")
    if (not isinstance(checks, list) or len(checks) != len(REQUIRED_CHECKS) or
            any(not isinstance(item, dict) or item.get("passed") is not True for item in checks) or
            {item.get("label") for item in checks} != REQUIRED_CHECKS):
        raise RuntimeError("Complete App checks are missing, repeated or unsuccessful.")
    return checks


def make_fixtures(root, run_id):
    ffmpeg = ROOT / "deps/executable/ffmpeg"
    for name in ("red", "blue", "compat"):
        (root / name).mkdir()
    base = [str(ffmpeg), "-hide_banner", "-loglevel", "error", "-nostdin"]
    settings = ["-c:v", "libx264", "-preset", "medium", "-crf", "18", "-bf", "2", "-g", "40",
                "-pix_fmt", "yuv420p", "-color_range", "tv", "-color_primaries", "bt709",
                "-color_trc", "bt709", "-colorspace", "bt709", "-c:a", "aac", "-shortest"]
    audio = ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=9"]
    subprocess.run(base + ["-f", "lavfi", "-i",
        "color=red:s=160x96:r=20:d=3[r];color=lime:s=160x96:r=20:d=3[g];"
        "color=blue:s=160x96:r=20:d=3[b];[r][g][b]concat=n=3:v=1:a=0"] + audio + settings +
        [str(root / "red/red.mp4")], check=True, timeout=45)
    subprocess.run(base + ["-f", "lavfi", "-i", "color=blue:s=160x96:r=20:d=9"] + audio + settings +
        [str(root / "blue/blue.mp4")], check=True, timeout=45)
    subtitle = root / "compat/subtitle.srt"
    subtitle.write_text("1\n00:00:00,000 --> 00:00:08,500\nSynthetic compatibility fixture\n", encoding="utf-8")
    subprocess.run(base + ["-i", str(root / "red/red.mp4"), "-i", str(subtitle), "-map", "0:v",
        "-map", "0:a", "-map", "1:s", "-c:v", "copy", "-c:a", "copy", "-c:s", "mov_text",
        str(root / "compat/compat.mp4")], check=True, timeout=45)
    (root / "native-app-fixture.json").write_text(json.dumps({
        "format": 1, "run_id": run_id,
        "fixtures": ["red/red.mp4", "blue/blue.mp4", "compat/compat.mp4"],
    }) + "\n", encoding="utf-8")


def build_command(workspace, source_packages, bundle_id):
    return ["xcodebuild", "-project", str(ROOT / "iina.xcodeproj"), "-scheme", "iina",
            "-configuration", "Release", "-derivedDataPath", str(workspace / "DerivedData"),
            "-clonedSourcePackagesDirPath", str(source_packages), "ONLY_ACTIVE_ARCH=YES", "ARCHS=arm64",
            "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=",
            "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES",
            f"PRODUCT_BUNDLE_IDENTIFIER={bundle_id}",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CHENGYING_NATIVE_APP_TESTS"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-packages", type=Path, required=True)
    parser.add_argument("--report-directory", type=Path, required=True)
    parser.add_argument("--production-app", type=Path, required=True)
    args = parser.parse_args()
    environment = dict(os.environ)
    validate_environment(environment)
    source_packages = args.source_packages.resolve(strict=True)
    report = args.report_directory.resolve()
    report.mkdir(parents=True, exist_ok=False)
    run_id = str(uuid.uuid4())
    bundle_id = "io.chengying.tests.native-app." + run_id.replace("-", "")
    summary = {"format": 1, "run_id": run_id, "passed": False, "cleanup": "pending"}
    try:
        production = args.production_app.resolve(strict=True)
        production_info = plistlib.loads((production / "Contents/Info.plist").read_bytes())
        if production_info.get("CFBundleIdentifier") != "io.github.SeanLi-Coder.ChengYingPlayer":
            raise RuntimeError("The regular build changed its production application identity.")
        release_strings = subprocess.check_output(["/usr/bin/strings", "-a",
            str(production / "Contents/MacOS/ChengYing")], timeout=30)
        if b"NATIVE_APP_TEST_" in release_strings or b"CHENGYING_NATIVE_APP_TEST_ROOT" in release_strings:
            raise RuntimeError("The CI-only driver was unexpectedly compiled into the regular App.")
        summary["regular_build_excludes_test_driver"] = True
        with TestAppWorkspace(prefix="native-full-app-") as owned:
            workspace = Path(owned)
            fixtures = workspace / "fixtures"
            fixtures.mkdir()
            make_fixtures(fixtures, run_id)
            with (report / "build.log").open("wb") as log:
                subprocess.run(build_command(workspace, source_packages, bundle_id), cwd=ROOT,
                               env=environment, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=900)
            app = workspace / "DerivedData/Build/Products/Release/ChengYing.app"
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            if info.get("CFBundleIdentifier") != bundle_id:
                raise RuntimeError("The test build did not use its isolated application identity.")
            executable = app / "Contents/MacOS/ChengYing"
            if not executable.is_file() or executable.is_symlink():
                raise RuntimeError("The expected test executable is missing.")
            environment.update({"CHENGYING_NATIVE_PLAYBACK": "1", "NSUnbufferedIO": "YES",
                "CHENGYING_NATIVE_APP_TEST_ROOT": str(fixtures), "CHENGYING_NATIVE_APP_TEST_RUN_ID": run_id})
            with (report / "app.log").open("wb") as log:
                result = subprocess.run([str(executable), "--no-stdin"], cwd=workspace, env=environment,
                    stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, timeout=150)
            output = fixtures / "result.json"
            if not output.is_file() or output.is_symlink():
                raise RuntimeError("The complete App produced no test result.")
            result_data = json.loads(output.read_text())
            (report / "result.json").write_text(json.dumps(result_data, indent=2) + "\n")
            summary["app_exit_code"] = result.returncode
            summary["checks"] = validate_result(result_data, run_id=run_id, exit_code=result.returncode)
        summary.update(passed=True, cleanup="completed")
        print("PASS: Complete native App test and owned workspace cleanup", flush=True)
    except BaseException:
        summary["cleanup"] = "unconfirmed"
        raise
    finally:
        (report / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()
