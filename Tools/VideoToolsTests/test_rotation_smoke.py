"""Offline checks for the native smoke's output oracle; no App is launched."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from app_rotation_smoke import (
    check_export_metadata,
    expected_dimensions,
    new_rotation_outputs,
    rotation_outputs,
)


class RotationSmokeOracleTests(unittest.TestCase):
    def test_accepts_new_mov_export_of_mp4_and_rejects_prior_or_wrong_outputs(self):
        with tempfile.TemporaryDirectory(prefix="rotation-smoke-oracle-") as directory:
            source = Path(directory) / "sample.mp4"
            old = source.with_name("sample_rotated_90.mov")
            old.touch()
            previous = rotation_outputs(source, 90)
            self.assertEqual(new_rotation_outputs(source, 90, previous), [])
            for name in ("sample_rotated_900.mov", "sample_rotated_270.mov",
                         "sample_rotated_90.partial.mov", "sample_rotated_90.log"):
                source.with_name(name).touch()
            self.assertEqual(new_rotation_outputs(source, 90, previous), [])
            new = source.with_name("sample_rotated_90_2.mov")
            new.touch()
            self.assertEqual(new_rotation_outputs(source, 90, previous), [new])

    def test_accepts_supported_output_containers(self):
        with tempfile.TemporaryDirectory(prefix="rotation-smoke-oracle-") as directory:
            source = Path(directory) / "sample.mp4"
            expected = {source.with_name(f"sample_rotated_90{suffix}")
                        for suffix in (".mp4", ".m4v", ".mov", ".mkv")}
            for output in expected:
                output.touch()
            self.assertEqual(rotation_outputs(source, 90), expected)

    def test_source_display_rotation_is_included_in_dimension_oracle(self):
        video = {"width": 1920, "height": 1080,
                 "side_data_list": [{"side_data_type": "Display Matrix", "rotation": -90}]}
        self.assertEqual(expected_dimensions(video, 90), (1920, 1080))
        self.assertEqual(expected_dimensions(video, 180), (1080, 1920))
        self.assertEqual(expected_dimensions({"width": 1920, "height": 1080}, 90), (1080, 1920))

    def test_rejects_wrong_dimensions_and_unbaked_display_transform(self):
        video = {"width": 1920, "height": 1080}
        check_export_metadata(video, (1920, 1080))
        with self.assertRaisesRegex(AssertionError, "dimensions"):
            check_export_metadata(video, (1080, 1920))
        with self.assertRaisesRegex(AssertionError, "rotation metadata"):
            check_export_metadata({**video, "tags": {"rotate": "90"}}, (1920, 1080))
        with self.assertRaisesRegex(AssertionError, "display transform"):
            check_export_metadata({**video, "side_data_list": [
                {"side_data_type": "Display Matrix", "rotation": 0}
            ]}, (1920, 1080))


if __name__ == "__main__":
    unittest.main()
