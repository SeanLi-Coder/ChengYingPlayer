"""Validate production packaging, localization, and termination guard wiring."""

import json
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]


def plist(path):
    return json.loads(subprocess.check_output(
        ["plutil", "-convert", "json", "-o", "-", str(path)]
    ))


class IntegrationTests(unittest.TestCase):
    def test_sources_are_compiled_by_production_target(self):
        objects = plist(ROOT / "iina.xcodeproj/project.pbxproj")["objects"]
        targets = [value for value in objects.values()
                   if value.get("isa") == "PBXNativeTarget" and value.get("name") == "iina"]
        self.assertEqual(len(targets), 1)
        sources = [objects[objects[file_id]["fileRef"]].get("path")
                   for phase_id in targets[0]["buildPhases"]
                   for phase in [objects[phase_id]]
                   if phase["isa"] == "PBXSourcesBuildPhase"
                   for file_id in phase["files"]]
        for name in ("PlaybackFileTags.swift", "PlaybackFileTagController.swift"):
            self.assertEqual(sources.count(name), 1, name)

    def test_localizations_cover_menu_errors_and_quit(self):
        backend = (ROOT / "iina/PlaybackFileTags.swift").read_text()
        enum = backend.split("enum TagError: String, Error {", 1)[1].split("}", 1)[0]
        errors = [value or name for name, value in re.findall(
            r'case (\w+)(?: = "([^"]+)")?', enum
        )]
        controller = (ROOT / "iina/PlaybackFileTagController.swift").read_text()
        keys = set(re.findall(r'(?:Self\.)?text\("([^"]+)"', controller))
        keys.discard("error.")
        keys.update("error." + error for error in errors)
        keys.update(("quit.title", "quit.detail"))
        for language in ("en", "zh-Hans", "zh-Hant"):
            strings = plist(ROOT / f"iina/{language}.lproj/PlaylistBrowser.strings")
            for key in keys:
                with self.subTest(language=language, key=key):
                    self.assertTrue(strings.get("file-tags." + key), key)
            for key in ("add", "remove", "legacy", "failed"):
                self.assertEqual(strings["file-tags." + key].count("%@"), 1)

    def test_quit_guards_precede_any_shutdown(self):
        source = (ROOT / "iina/AppDelegate.swift").read_text()
        last_window = source.split(
            "func applicationShouldTerminateAfterLastWindowClosed(", 1
        )[1].split("func applicationShouldTerminate(", 1)[0]
        self.assertIn("guard PlaybackFileTags.pendingWriteCount == 0 else { return false }", last_window)
        terminate = source.split("func applicationShouldTerminate(", 1)[1]
        prefix = terminate.split("isTerminating = true", 1)[0]
        self.assertIn("guard PlaybackFileTags.pendingWriteCount == 0 else {", prefix)
        guard = prefix.split("guard PlaybackFileTags.pendingWriteCount == 0 else {", 1)[1].split("}", 1)[0]
        self.assertIn('playlistBrowserString("file-tags.quit.title")', guard)
        self.assertIn('playlistBrowserString("file-tags.quit.detail")', guard)
        self.assertIn("return .terminateCancel", guard)
        self.assertLess(prefix.index("PlaybackFileTags.pendingWriteCount"),
                        prefix.index("updateCoordinator.shouldAllowTerminationForUpdate()"))

    def test_ci_runs_behavioral_regressions(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        for command in ("bash Tools/PlaybackFileTagTests/run.sh",
                        "bash Tools/PlaybackFileTagUITests/run.sh",
                        "python3 -B Tools/PlaybackFileTagTests/test_integration.py"):
            self.assertIn(command, workflow)


if __name__ == "__main__":
    unittest.main(verbosity=2)
