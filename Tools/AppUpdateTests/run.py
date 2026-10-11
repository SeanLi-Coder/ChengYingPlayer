#!/usr/bin/env python3
"""Run native update fixtures in an owned application workspace."""

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(PROJECT_ROOT))

from other.test_app_workspace import TestAppWorkspace


def isolation_fixtures(workspace):
    # Extract the production property and action, rather than duplicating their annotations.
    source = (PROJECT_ROOT / "iina/AppDelegate.swift").read_text()
    start, end = "  // MARK: - Application Updates\n", "  // MARK: - App Delegate\n"
    if source.count(start) != 1 or source.count(end) != 1:
        raise RuntimeError("Application update source section is missing or ambiguous.")
    section = source.split(start, 1)[1].split(end, 1)[0]
    if "lazy var updateCoordinator" not in section or "func checkForUpdates(" not in section:
        raise RuntimeError("Application update property or menu action is missing.")
    template = (PROJECT_ROOT / "Tools/AppUpdateTests/AppDelegateIsolation.swift.in").read_text()
    marker = "  // APP_UPDATE_SOURCE_SECTION"
    if template.count(marker) != 1:
        raise RuntimeError("AppDelegate isolation template marker is invalid.")
    positive = workspace / "AppDelegateIsolation.swift"
    negative = workspace / "AppDelegateIsolationNegative.swift"
    positive.write_text(template.replace(marker, section.rstrip()))
    # Prove this fixture detects the original regression without changing production files.
    negative_section, replacements = re.subn(
        r"@MainActor\s+(?=private\(set\) lazy var updateCoordinator)", "", section)
    if replacements != 1:
        raise RuntimeError("Expected one explicit main-actor annotation on the updater property.")
    negative.write_text(template.replace(marker, negative_section.rstrip()))
    return positive, negative


def check_negative_control(command, log):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, errors="replace")
    log.write_text(result.stdout)
    if result.returncode == 0:
        raise RuntimeError("The AppDelegate fixture did not detect the missing main-actor annotation.")
    if "error: call to main actor-isolated initializer" not in result.stdout:
        print(result.stdout, file=sys.stderr, end="")
        raise RuntimeError("The AppDelegate negative control failed for an unexpected reason.")
    print("PASS: Production AppDelegate update entry points compile in Swift 5; "
          "the unisolated negative control is rejected.", flush=True)


def run_native_fixture(command, log):
    result = subprocess.run(command, stderr=subprocess.PIPE, text=True, errors="replace")
    log.write_text(result.stderr)
    print(result.stderr, file=sys.stderr, end="", flush=True)
    if re.search(r"Unable to simultaneously satisfy constraints|Unsatisfiable constraints", result.stderr):
        raise RuntimeError("Native update window emitted Auto Layout conflicts.")
    result.check_returncode()


def main():
    framework_value = os.environ.get("SPARKLE_FRAMEWORK_DIR")
    if not framework_value:
        raise SystemExit("Set SPARKLE_FRAMEWORK_DIR to the Sparkle 2.10 macos-arm64_x86_64 artifact directory")
    framework = Path(framework_value).resolve()
    if not (framework / "Sparkle.framework").is_dir():
        raise SystemExit("SPARKLE_FRAMEWORK_DIR does not contain Sparkle.framework")
    language = os.environ.get("APP_UPDATE_TEST_LANGUAGE") or "en"
    with TestAppWorkspace(prefix="app-updates-") as directory:
        workspace = Path(directory)
        contents = workspace / "AppUpdateTests.app" / "Contents"
        executable = contents / "MacOS/AppUpdateTests"
        executable.parent.mkdir(parents=True)
        snapshot_value = os.environ.get("APP_UPDATE_SNAPSHOT_DIR")
        snapshots = Path(snapshot_value).resolve() if snapshot_value else workspace / "snapshots"
        snapshots.mkdir(parents=True, exist_ok=True)
        shutil.copy2(PROJECT_ROOT / "Tools/AppUpdateTests/Info.plist", contents / "Info.plist")
        for locale in ("en", "zh-Hans", "zh-Hant"):
            resources = contents / "Resources" / f"{locale}.lproj"
            resources.mkdir(parents=True)
            strings = PROJECT_ROOT / "iina" / f"{locale}.lproj/Updates.strings"
            shutil.copy2(strings, resources)
            subprocess.run(["plutil", "-lint", str(strings)], check=True)

        sources = [str(PROJECT_ROOT / "iina/Updates" / name) for name in (
            "UpdatePolicy.swift", "AppUpdateWindowController.swift", "AppUpdateUserDriver.swift",
            "AppUpdateCoordinator.swift")]
        compiler = ["xcrun", "swiftc", "-swift-version", "5", "-target", "arm64-apple-macos12",
                    "-F", str(framework)]
        positive, negative = isolation_fixtures(workspace)
        subprocess.run([*compiler, "-typecheck", *sources, str(positive)], check=True)
        check_negative_control([*compiler, "-typecheck", *sources, str(negative)],
                               workspace / "isolation-negative.log")
        subprocess.run([*compiler, "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", str(framework),
                        "-o", str(executable), *sources,
                        str(PROJECT_ROOT / "Tools/AppUpdateTests/main.swift")], check=True)
        run_native_fixture([str(executable), str(snapshots), "-AppleLanguages", f"({language})"],
                           workspace / "stderr.log")


if __name__ == "__main__":
    main()
