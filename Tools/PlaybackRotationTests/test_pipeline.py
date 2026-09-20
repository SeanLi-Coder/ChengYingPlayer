"""Require real rotation regressions after their clean-runner dependencies."""

import unittest
from pathlib import Path


class RotationPipelineTests(unittest.TestCase):
    def test_native_rotation_follows_both_playback_and_media_builds(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/ci.yml").read_text()
        names = (
            "Test rotation teardown with original and patched playback source",
            "Build playback libraries from pinned source",
            "Build bundled video tools",
            "Test real rotation at EOF, stop, and file replacement",
            "Build application",
            "Assemble and verify application",
            "Test real application rapid rotation preview",
            "Package and verify Apple Silicon DMG",
        )
        positions = []
        for name in names:
            marker = f"      - name: {name}\n"
            self.assertEqual(workflow.count(marker), 1, name)
            positions.append(workflow.index(marker))
        self.assertEqual(positions, sorted(positions))


if __name__ == "__main__":
    unittest.main()
