from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import source_materials as sources
import verify_build_environment as environment


def test_every_runtime_has_a_same_version_source():
    runtime = json.loads((ROOT / "runtime-artifacts.json").read_text())
    locked = {environment.normalized(item["name"]): item for item in sources.records()}
    for item in runtime["artifacts"]:
        assert (
            locked[environment.normalized(item["name"])]["version"] == item["version"]
        )
    assert locked["mutagen"]["license"] == "GPL-2.0-or-later"
    assert locked["certifi"]["license"] == "MPL-2.0"
    assert locked["node"]["version"] == "24.18.1"
    assert "deno" not in locked


@pytest.mark.parametrize(
    "field,value",
    [
        ("filename", "../../escape.tar.gz"),
        ("sha256", "wrong"),
        ("url", "http://example.com/source"),
        ("url", "https://user:secret@example.com/source"),
    ],
)
def test_source_manifest_rejects_unsafe_records(tmp_path, field, value):
    item = dict(sources.records()[0])
    item[field] = value
    manifest = tmp_path / "manifest.json"
    manifest.write_text(json.dumps({"schema_version": 1, "artifacts": [item]}))
    with pytest.raises(ValueError):
        sources.records(manifest)


def test_verified_source_cache_never_downloads_again(tmp_path, monkeypatch):
    data = b"verified fixture"
    source = tmp_path / "source.tar.gz"
    source.write_bytes(data)
    item = {"filename": source.name, "sha256": hashlib.sha256(data).hexdigest()}
    monkeypatch.setattr(
        sources.subprocess, "run", lambda *a, **k: pytest.fail("unexpected network")
    )
    assert sources.fetch(item, tmp_path) == source


def test_source_cache_rejects_symlinks(tmp_path):
    target = tmp_path / "target"
    target.write_text("preserved")
    (tmp_path / "source.tar.gz").symlink_to(target)
    with pytest.raises(ValueError, match="symlinks"):
        sources.fetch({"filename": "source.tar.gz"}, tmp_path)
    assert target.read_text() == "preserved"


def test_clean_build_packages_are_accepted():
    environment.validate_installed({**environment.expected_packages(), "pip": "24.3.1"})


@pytest.mark.parametrize("extra", ["deno", "httpx2", "httpcore2", "pytest"])
def test_unpinned_build_environment_is_rejected(extra):
    with pytest.raises(RuntimeError, match="unexpected packages"):
        environment.validate_installed(
            {**environment.expected_packages(), extra: "1.0"}
        )
