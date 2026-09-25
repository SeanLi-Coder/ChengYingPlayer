"""Exercise strict previous-release asset selection without network access."""

from __future__ import annotations

import copy
import hashlib
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "other"))
import build_delta_update as builder
import download_previous_release as previous


def fixture_release(directory, tag="v99.0.0"):
    archive_name = f"ChengYingPlayer-{tag}-Apple-Silicon.dmg"
    values = {
        archive_name: b"immutable signed archive fixture",
        "appcast.xml": b"signed feed fixture",
    }
    values[archive_name + ".sha256"] = (
        f"{hashlib.sha256(values[archive_name]).hexdigest()}  {archive_name}\n".encode()
    )
    release = {
        "tag_name": tag,
        "html_url": f"{previous.RELEASES}/tag/{tag}",
        "draft": False,
        "prerelease": False,
        "published_at": "2026-09-26T00:00:00Z",
        "assets": [],
    }
    for name, value in values.items():
        (directory / name).write_bytes(value)
        release["assets"].append(
            {
                "name": name,
                "state": "uploaded",
                "size": len(value),
                "digest": f"sha256:{hashlib.sha256(value).hexdigest()}",
                "browser_download_url": f"{previous.RELEASES}/download/{tag}/{name}",
            }
        )
    return release


class PreviousAssets(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chengying-delta-policy-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.release = fixture_release(self.directory)
        self.tag = "v99.0.1"

    def test_complete_immutable_base_is_accepted(self):
        tag, archive, feed = previous.verify_downloads(
            self.directory, self.release, self.tag
        )
        self.assertEqual(tag, "v99.0.0")
        self.assertEqual(archive.suffix, ".dmg")
        self.assertEqual(feed.name, "appcast.xml")

    def test_optional_historical_delta_does_not_need_download(self):
        self.release["assets"].append({"name": "historic.delta"})
        self.assertEqual(len(previous.release_assets(self.release, self.tag)[1]), 3)

    def test_release_identity_and_publication_are_strict(self):
        for key, value in (
            ("draft", True),
            ("prerelease", True),
            ("published_at", ""),
            ("html_url", "https://github.com/other/repo/releases/tag/v99.0.0"),
            ("tag_name", "v99.0.0-rc1"),
            ("tag_name", "../../escape"),
            ("tag_name", "v99.0.1"),
            ("tag_name", "v100.0.0"),
        ):
            with self.subTest(key=key, value=value):
                changed = copy.deepcopy(self.release)
                changed[key] = value
                with self.assertRaises(ValueError):
                    previous.release_assets(changed, self.tag)

    def test_duplicate_missing_and_malformed_assets_fail(self):
        for assets in (
            None,
            [],
            [{}],
            self.release["assets"] * 2,
            self.release["assets"][:-1],
        ):
            with self.subTest(assets=assets):
                changed = dict(self.release, assets=assets)
                with self.assertRaises(ValueError):
                    previous.release_assets(changed, self.tag)

    def test_asset_urls_digests_state_and_lengths_are_strict(self):
        for key, value in (
            ("state", "new"),
            ("size", 0),
            ("size", True),
            ("size", 4 * 1024**3 + 1),
            ("digest", None),
            ("digest", "sha256:" + "A" * 64),
            ("browser_download_url", "http://github.com/archive.dmg"),
            (
                "browser_download_url",
                self.release["assets"][0]["browser_download_url"] + "?download=1",
            ),
        ):
            with self.subTest(key=key, value=value):
                changed = copy.deepcopy(self.release)
                changed["assets"][0][key] = value
                with self.assertRaises(ValueError):
                    previous.release_assets(changed, self.tag)

    def test_downloaded_bytes_are_checked_even_when_length_is_unchanged(self):
        path = self.directory / self.release["assets"][0]["name"]
        path.write_bytes(b"X" + path.read_bytes()[1:])
        with self.assertRaisesRegex(ValueError, "published digest"):
            previous.verify_downloads(self.directory, self.release, self.tag)

    def test_checksum_must_name_exact_asset_even_with_matching_api_digest(self):
        asset = self.release["assets"][-1]
        path = self.directory / asset["name"]
        path.write_bytes(
            path.read_bytes().replace(b"ChengYingPlayer", b"OtherAppPlayer")
        )
        asset["size"] = path.stat().st_size
        asset["digest"] = f"sha256:{previous.digest(path)}"
        with self.assertRaisesRegex(ValueError, "checksum"):
            previous.verify_downloads(self.directory, self.release, self.tag)

    def test_symlink_asset_fails(self):
        path = self.directory / self.release["assets"][0]["name"]
        target = self.directory / "target"
        path.rename(target)
        path.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "regular file"):
            previous.verify_downloads(self.directory, self.release, self.tag)

    def test_metadata_limit_is_checked_before_mount(self):
        (self.directory / "release.json").write_bytes(b" " * (4 * 1024**2 + 1))
        with patch.object(builder.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "too large"):
                builder.authenticated_previous_app(
                    self.directory, {}, self.tag, self.directory
                )
            run.assert_not_called()

    def test_invalid_base_digest_is_rejected_before_mount_or_signing(self):
        self.release["assets"][0]["digest"] = "sha256:" + "0" * 64
        (self.directory / "release.json").write_text(json.dumps(self.release))
        with patch.object(builder.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "published digest"):
                builder.authenticated_previous_app(
                    self.directory, {}, self.tag, self.directory
                )
            run.assert_not_called()

    def test_existing_download_output_is_never_replaced(self):
        with patch.object(previous.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "new directory"):
                previous.download(self.directory, self.tag)
            run.assert_not_called()

    def test_tree_manifest_distinguishes_bytes_modes_and_symlinks(self):
        app = self.directory / "App.app"
        app.mkdir()
        data = app / "resource"
        data.write_bytes(b"same size")
        before = builder.tree_manifest(app)
        data.write_bytes(b"new bytes")
        self.assertNotEqual(before, builder.tree_manifest(app))
        data.write_bytes(b"same size")
        data.chmod(stat.S_IMODE(data.stat().st_mode) ^ stat.S_IXUSR)
        self.assertNotEqual(before, builder.tree_manifest(app))
        data.unlink()
        data.symlink_to("target")
        self.assertNotEqual(before, builder.tree_manifest(app))

    def test_tree_manifest_does_not_follow_symlink(self):
        app = self.directory / "App.app"
        app.mkdir()
        (app / "outside").symlink_to(self.directory)
        manifest = builder.tree_manifest(app)
        self.assertEqual(set(manifest), {".", "outside"})

    def test_tree_manifest_rejects_special_files_without_reading_them(self):
        app = self.directory / "App.app"
        app.mkdir()
        os.mkfifo(app / "pipe")
        with self.assertRaisesRegex(ValueError, "special file"):
            builder.tree_manifest(app)


if __name__ == "__main__":
    unittest.main(verbosity=2)
