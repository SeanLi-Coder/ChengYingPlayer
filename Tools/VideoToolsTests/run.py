#!/usr/bin/env python3
"""Run native video tool fixtures in an owned, automatically retired workspace."""

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(PROJECT_ROOT))

from other.test_app_workspace import TestAppWorkspace


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--controller-ref", help="Use controller source from this local Git commit without fetching")
    parser.add_argument("--language", choices=("en", "zh-Hans", "zh-Hant"), help="Run one language instead of all three")
    parser.add_argument("--preview-case", action="append",
                        choices=("opening", "input", "markers", "rounding", "invalid", "lifecycle", "navigation", "waiting"),
                        help="Run an isolated automatic-preview case; repeat to select multiple cases")
    parser.add_argument("--preview-wait-mode", choices=("observed", "fixed"), default="observed",
                        help="Compare observed-state waiting with the legacy fixed wait in the waiting case")
    parser.add_argument("--preview-repeat", type=int, default=1,
                        help="Repeat isolated preview cases in fresh processes without recompiling")
    parser.add_argument("--preview-window-height", type=float, default=720,
                        help="Maximum native preview fixture content height, also capped to the visible screen")
    parser.add_argument("--preview-run-loop-stall", type=float, default=0,
                        help="Block preview fixture timer delivery for this many seconds to test late dispatch")
    arguments = parser.parse_args()
    if arguments.preview_wait_mode == "fixed" and arguments.preview_case != ["waiting"]:
        parser.error("--preview-wait-mode fixed requires only --preview-case waiting")
    if not 1 <= arguments.preview_repeat <= 100 or (arguments.preview_repeat != 1 and not arguments.preview_case):
        parser.error("--preview-repeat requires --preview-case and must be between 1 and 100")
    if not 240 <= arguments.preview_window_height <= 2000:
        parser.error("--preview-window-height must be between 240 and 2000")
    if not 0 <= arguments.preview_run_loop_stall <= 1:
        parser.error("--preview-run-loop-stall must be between 0 and 1 second")
    languages = (arguments.language,) if arguments.language else ("en", "zh-Hans", "zh-Hant")
    controller_path = "iina/VideoTools/VideoToolsViewController.swift"
    baseline = None
    if arguments.controller_ref:
        try:
            commit = subprocess.check_output(
                ["git", "rev-parse", "--verify", f"{arguments.controller_ref}^{{commit}}"],
                cwd=PROJECT_ROOT, text=True, stderr=subprocess.DEVNULL).strip()
            baseline = subprocess.check_output(["git", "show", f"{commit}:{controller_path}"],
                                               cwd=PROJECT_ROOT, text=True, stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            parser.error("The requested controller source is not available locally; no network fetch was attempted.")
        print(f"Native UI controller baseline: {commit}", flush=True)
    with TestAppWorkspace(prefix="video-tools-") as directory:
        root = Path(directory)

        def bundle(name):
            contents = root / f"{name}.app" / "Contents"
            executable = contents / "MacOS" / name
            executable.parent.mkdir(parents=True)
            with (contents / "Info.plist").open("wb") as output:
                plistlib.dump({
                    "CFBundleIdentifier": f"io.github.SeanLi-Coder.ChengYingPlayer.{name}",
                    "CFBundleExecutable": name, "CFBundleDevelopmentRegion": "en", "CFBundlePackageType": "APPL",
                }, output)
            for language in ("en", "zh-Hans", "zh-Hant"):
                resources = contents / "Resources" / f"{language}.lproj"
                resources.mkdir(parents=True)
                for table in ("Localizable.strings", "MediaInfo.strings"):
                    shutil.copy2(PROJECT_ROOT / "iina" / f"{language}.lproj" / table, resources)
            return executable

        def compile_sources(executable, sources):
            subprocess.run(["xcrun", "swiftc", "-o", str(executable),
                            *[str(PROJECT_ROOT / source) for source in sources]], check=True)

        actual_controller = controller_path
        if baseline is not None:
            baseline_path = root / "VideoToolsViewController.swift"
            baseline_path.write_text(baseline)
            actual_controller = str(baseline_path)
        common = ["iina/Updates/UpdateWorkAdmission.swift", "iina/VideoTools/VideoToolsModels.swift",
                  "iina/VideoTools/VideoToolsRotationCoordinator.swift"]
        executable = bundle("NativeControlsTests")
        compile_sources(executable, [*common, "Tools/VideoToolsTests/Stubs.swift", "iina/ChengYingStyle.swift",
            "iina/MediaInfo/MediaInfoModels.swift", "iina/VideoTools/VideoToolsShortcuts.swift",
            "iina/VideoTools/VideoToolsLoopPolicy.swift", "iina/VideoTools/VideoToolsPlayerBridge.swift",
            actual_controller, "Tools/VideoToolsTests/ShortcutTests.swift", "Tools/VideoToolsTests/LoopPolicyTests.swift",
            "Tools/VideoToolsTests/main.swift"])
        environment = os.environ.copy()
        environment.pop("CHENGYING_PREVIEW_REGRESSION_CASE", None)
        environment["CHENGYING_PREVIEW_WAIT_MODE"] = arguments.preview_wait_mode
        environment["CHENGYING_PREVIEW_WINDOW_HEIGHT"] = str(arguments.preview_window_height)
        environment["CHENGYING_PREVIEW_RUN_LOOP_STALL"] = str(arguments.preview_run_loop_stall)
        failures = []
        for scenario in (arguments.preview_case or [None]) * arguments.preview_repeat:
            if scenario:
                environment["CHENGYING_PREVIEW_REGRESSION_CASE"] = scenario
            for language in languages:
                result = subprocess.run([str(executable), "-AppleLanguages", f"({language})"],
                                        check=not bool(scenario), env=environment)
                if result.returncode:
                    failures.append((scenario, language))
                    print(f"Automatic-preview regression failed: {scenario} / {language}", flush=True)
        if failures:
            raise SystemExit(1)
        if arguments.preview_case:
            return
        rotation = root / "RotationCoordinatorTests"
        compile_sources(rotation, [*common, "Tools/VideoToolsTests/RotationCoordinatorTests.swift"])
        subprocess.run([str(rotation)], check=True)
        tasks = bundle("TaskManagerTests")
        compile_sources(tasks, [*common, "iina/VideoTools/VideoToolsTaskManager.swift",
                               "Tools/VideoToolsTests/TaskManagerTests.swift"])
        for language in languages:
            subprocess.run([str(tasks), "-AppleLanguages", f"({language})"], check=True)


if __name__ == "__main__":
    main()
