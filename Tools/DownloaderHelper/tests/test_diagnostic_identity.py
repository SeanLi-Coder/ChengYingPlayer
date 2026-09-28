"""Keep diagnostic identity tied to sealed source without user-data access."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import diagnostic_identity as identity


@pytest.fixture
def source(tmp_path):
    root = tmp_path / "project"
    helper = root / "Tools/DownloaderHelper"
    helper.mkdir(parents=True)
    (helper / "static").mkdir()
    (root / "Configs").mkdir()
    (root / "Configs/Deployment.xcconfig").write_text(
        "CURRENT_PROJECT_VERSION = 58\n\nMARKETING_VERSION = 0.2.47\n"
    )
    (helper / "helper.py").write_text("pass\n")
    (helper / "static/diagnostics.js").write_text('"use strict";\n')
    return helper


def test_fingerprint_covers_native_sources_and_static_assets_not_untracked_data(source):
    before = identity.build_identity(source)
    assert before["player_version"] == "0.2.47"
    assert before["player_build"] == "58"
    assert len(before["helper_build_id"]) == 64
    (source / "data").mkdir()
    (source / "data/private.json").write_text('"never-read"')
    (source / "untracked-private.json").write_text('"never-read"')
    assert identity.build_identity(source) == before
    (source / "static/diagnostics.js").write_text('"use strict";\n// Change\n')
    changed = identity.build_identity(source)
    assert changed["helper_build_id"] != before["helper_build_id"]
    assert identity.build_identity(source) == changed


@pytest.mark.parametrize("key,value", [
    ("schema_version", True), ("schema_version", 2), ("player_version", "/Users/private"),
    ("player_build", "58\nsecret"), ("helper_build_id", "cookie=private"),
])
def test_invalid_identity_fails_closed(source, key, value):
    data = identity.build_identity(source)
    data[key] = value
    with pytest.raises(ValueError, match="Invalid bundled build identity"):
        identity._validate_identity(data)


def test_frozen_reads_only_sealed_resource_and_never_falls_back(source, monkeypatch):
    data = identity.build_identity(source)
    (source / "diagnostic-build.json").write_text(json.dumps(data))
    monkeypatch.setattr(identity, "ROOT", source)
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(identity, "build_identity", lambda: pytest.fail("No development fallback"))
    monkeypatch.setitem(sys.modules, "app.build_info", SimpleNamespace(APP_VERSION="1.2.23", BUILD_ID="a" * 12))
    result = identity.runtime_identity()
    assert result["identity_source"] == "bundled"
    assert result["player_version"] == "0.2.47"
    assert result["player_build"] == "58"
    assert result["engine_version"] == "1.2.23"
    (source / "diagnostic-build.json").write_text("x" * 4097)
    assert identity.runtime_identity()["identity_source"] == "unavailable"
    (source / "diagnostic-build.json").unlink()
    assert identity.runtime_identity()["identity_source"] == "unavailable"


def test_build_metadata_matches_current_player_config():
    result = identity.build_identity()
    assert identity._validate_identity(result)["helper_build_id"] == result["helper_build_id"]
