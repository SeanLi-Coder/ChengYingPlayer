"""Fail closed when the tested guide loses its production entry points or packaging."""

import json
import re
import subprocess
import sys
from pathlib import Path


def check(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL: {message}")
    print(f"PASS: {message}")


def body(source: str, signature: str) -> str:
    check(source.count(signature) == 1, f"The source has exactly one {signature}")
    start = source.index("{", source.index(signature))
    # Ignore braces inside comments and string literals when locating the method end.
    masked = re.sub(
        r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/',
        lambda match: " " * len(match.group()),
        source,
        flags=re.DOTALL,
    )
    depth = 0
    for index in range(start, len(masked)):
        depth += (masked[index] == "{") - (masked[index] == "}")
        if depth == 0:
            return source[start + 1 : index]
    raise SystemExit(f"FAIL: The source block is unterminated: {signature}")


def plist(path: Path) -> dict:
    return json.loads(
        subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)])
    )


def main() -> None:
    root = Path(sys.argv[1])
    delegate = (root / "iina/AppDelegate.swift").read_text()
    welcome = (root / "iina/InitialWindowController.swift").read_text()
    startup = body(delegate, "func checkForShowingInitialWindow()")
    check(
        "guard !isTerminating else { return }" in startup,
        "Startup cannot present a guide while termination is in progress",
    )
    check(
        startup.index("showWelcomeWindow()")
        < startup.index("fileAccessGuide.scheduleLaunchOffer(")
        and "isInteractive: !commandLineStatus.isCommandLine" in startup,
        "Interactive startup schedules the guide after welcome and explicitly excludes CLI playback",
    )
    check(
        "#selector(self.checkForShowingInitialWindow)"
        in body(delegate, "if !commandLineStatus.isCommandLine"),
        "The normal startup timer itself is excluded from command-line playback",
    )
    for method in ["applicationWillFinishLaunching", "applicationDidFinishLaunching"]:
        launch = body(delegate, f"func {method}(")
        check(
            "guideWindow.show" not in launch,
            f"{method} does not restore the former version-change advertising window",
        )
    termination = body(delegate, "func applicationShouldTerminate(")
    check(
        termination.index("fileAccessGuide.cancelLaunchOffer()")
        < termination.index("window.close()"),
        "Termination cancels pending onboarding before closing application windows",
    )
    check(
        "installFileAccessMenuItem()" in body(delegate, "private func getReady()"),
        "Application menu setup installs the manual guide entry",
    )
    menu = body(delegate, "private func installFileAccessMenuItem()")
    check(
        "#selector(showFileAccessGuide(_:))" in menu
        and "item.target = self" in menu
        and "!menu.items.contains" in menu,
        "The native guide menu action targets the delegate and avoids duplicate entries",
    )
    check(
        "fileAccessGuide.show()"
        in body(delegate, "@IBAction func showFileAccessGuide("),
        "The manual app-menu action uses the real coordinator",
    )
    check(
        "fileAccessButton.action = #selector(openFileAccessGuide)" in welcome
        and 'NSSelectorFromString("showFileAccessGuide:")'
        in body(welcome, "private func openFileAccessGuide()"),
        "The welcome button routes to the same manually reopenable guide",
    )

    objects = plist(root / "iina.xcodeproj/project.pbxproj")["objects"]
    targets = [
        value
        for value in objects.values()
        if value.get("isa") == "PBXNativeTarget" and value.get("name") == "iina"
    ]
    check(len(targets) == 1, "The project contains one production application target")
    phases = [objects[identifier] for identifier in targets[0]["buildPhases"]]
    sources = [
        objects[objects[identifier]["fileRef"]]
        for phase in phases
        if phase["isa"] == "PBXSourcesBuildPhase"
        for identifier in phase["files"]
    ]
    for name in [
        "FileAccessGuideWindowController.swift",
        "FileAccessGuideCoordinator.swift",
    ]:
        check(
            sum(source.get("path") == name for source in sources) == 1,
            f"The application compiles {name} exactly once",
        )
    resources = [
        objects[objects[identifier]["fileRef"]]
        for phase in phases
        if phase["isa"] == "PBXResourcesBuildPhase"
        for identifier in phase["files"]
    ]
    variants = [
        resource
        for resource in resources
        if resource.get("name") == "FileAccess.strings"
    ]
    check(
        len(variants) == 1 and variants[0]["isa"] == "PBXVariantGroup",
        "The application embeds the file-access localization variant group",
    )
    localized_paths = {
        objects[identifier]["path"] for identifier in variants[0]["children"]
    }
    check(
        localized_paths
        == {"en.lproj/FileAccess.strings", "zh-Hans.lproj/FileAccess.strings"},
        "Both tested localizations are included in the production resources",
    )
    english = plist(root / "iina/en.lproj/FileAccess.strings")
    chinese = plist(root / "iina/zh-Hans.lproj/FileAccess.strings")
    check(
        english.keys() == chinese.keys()
        and all(english.values())
        and all(chinese.values()),
        "English and Chinese have matching nonempty file-access translation keys",
    )
    workflow = (root / ".github/workflows/ci.yml").read_text()
    check(
        sum(
            line.strip() == "bash Tools/FileAccessTests/run.sh"
            for line in workflow.splitlines()
        )
        == 1,
        "Release CI runs the real file-access guide regression suite exactly once",
    )
    print("File access production integration checks passed")


if __name__ == "__main__":
    main()
