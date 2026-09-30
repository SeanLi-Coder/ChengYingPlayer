"""Native author directories using synthetic state and discovery, never accounts."""

from __future__ import annotations

import json
import socket
import sys
import threading
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "vendor/rednote"))

import helper
from app import downloader as engine
from app import kuaishou as ks
from app.errors import MediaDownloadError
from app.models import (
    DownloadJob,
    ItemStatus,
    JobStatus,
    MediaType,
    OutputLayout,
    Platform,
    SourceKind,
)
from app.task_manager import DownloadManager

SOURCES = [
    (Platform.XIAOHONGSHU, SourceKind.PROFILE, "https://www.xiaohongshu.com/user/profile/0123456789abcdef01234567"),
    (Platform.XIAOHONGSHU, SourceKind.ITEM, "https://www.xiaohongshu.com/explore/0123456789abcdef01234567"),
    (Platform.DOUYIN, SourceKind.PROFILE, "https://www.douyin.com/user/fixture-author"),
    (Platform.DOUYIN, SourceKind.ITEM, "https://www.douyin.com/video/1234567890123456789"),
    (Platform.KUAISHOU, SourceKind.PROFILE, "https://www.kuaishou.com/profile/3xowner1"),
    (Platform.KUAISHOU, SourceKind.ITEM, "https://www.kuaishou.com/short-video/3xvideo1"),
    (Platform.BILIBILI, SourceKind.PROFILE, "https://space.bilibili.com/123456"),
    (Platform.BILIBILI, SourceKind.ITEM, "https://www.bilibili.com/video/BV1234567890"),
    (Platform.YOUTUBE, SourceKind.PROFILE, "https://www.youtube.com/@FixtureAuthor"),
    (Platform.YOUTUBE, SourceKind.ITEM, "https://www.youtube.com/watch?v=abcdefghijk"),
]


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    def forbidden(*args, **kwargs):
        raise AssertionError("This test must not connect to a network")

    monkeypatch.setattr(socket.socket, "connect", forbidden)
    monkeypatch.setattr(socket, "create_connection", forbidden)


@pytest.fixture
def manager(tmp_path):
    value = DownloadManager(
        state_dir=tmp_path / "state", default_output_root=tmp_path / "selected",
        new_job_output_layout=OutputLayout.AUTHOR,
    )
    try:
        yield value
    finally:
        value.shutdown()


@pytest.mark.parametrize(("platform", "kind", "url"), SOURCES)
def test_all_native_source_types_use_exact_selected_root(manager, tmp_path, platform, kind, url):
    selected = tmp_path / "app" / "data"
    job = manager.create_job(url, output_root=selected, cookie_browser=None, auto_start=False)
    assert (job.platform, job.source_kind, job.output_layout) == (platform, kind, OutputLayout.AUTHOR)
    assert manager.store.get(job.id).output_layout == OutputLayout.AUTHOR
    destination = manager._prepare_output_directory(job, "ABC")
    assert destination == selected / "ABC"
    assert destination.is_dir()
    assert sorted(path.name for path in selected.iterdir()) == ["ABC"]
    assert manager._engine_for_job(job).config.preserve_existing_files is True


def test_native_helper_changes_only_new_job_policy(tmp_path):
    manager = DownloadManager(state_dir=tmp_path / "state", default_output_root=tmp_path / "selected")
    try:
        old = manager.create_job(SOURCES[5][2], cookie_browser=None, auto_start=False)
        helper.configure_download_layout(SimpleNamespace(manager=manager))
        new = manager.create_job(SOURCES[5][2], cookie_browser=None, auto_start=False)
        assert manager.get_job(old.id).output_layout == OutputLayout.PLATFORM_AUTHOR
        assert manager.get_job(new.id).output_layout == OutputLayout.AUTHOR
        assert manager._prepare_output_directory(old, "ABC") == tmp_path / "selected" / "Kuaishou" / "ABC"
        assert manager._prepare_output_directory(new, "ABC") == tmp_path / "selected" / "ABC"
        assert manager._engine_for_job(old).config.preserve_existing_files is False
        assert manager._engine_for_job(new).config.preserve_existing_files is True
    finally:
        manager.shutdown()


@pytest.mark.parametrize("platform", list(Platform))
def test_independent_engine_keeps_legacy_default(tmp_path, platform):
    expected = tmp_path / "Kuaishou" / "ABC" if platform == Platform.KUAISHOU else tmp_path / "ABC"
    assert engine.platform_output_directory(platform, tmp_path, "ABC") == expected


@pytest.mark.parametrize("author", ["../../escape", "/absolute/name", "..", "a/b\\c", " ", None, "CON", "NUL.txt", "作者" * 200])
def test_author_sanitization_stays_one_direct_child(manager, tmp_path, author):
    job = manager.create_job(SOURCES[5][2], cookie_browser=None, auto_start=False)
    destination = manager._prepare_output_directory(job, author)
    assert destination.parent == tmp_path / "selected"
    assert destination.is_dir()
    assert len(destination.name.encode("utf-8")) <= 120


@pytest.mark.parametrize("platform", list(Platform))
def test_unknown_author_has_no_platform_named_parent(tmp_path, platform):
    assert engine.platform_output_directory(
        platform, tmp_path, "../", output_layout=OutputLayout.AUTHOR
    ) == tmp_path / "Unknown Author"


@pytest.mark.parametrize("kind", ["file", "symlink", "dangling"])
def test_existing_author_conflict_is_not_followed_or_replaced(manager, tmp_path, kind):
    destination = tmp_path / "selected" / "ABC"
    external = tmp_path / "unrelated"
    if kind == "file":
        destination.write_bytes(b"existing user bytes")
    else:
        if kind == "symlink":
            external.mkdir()
        destination.symlink_to(external, target_is_directory=True)
    job = manager.create_job(SOURCES[5][2], cookie_browser=None, auto_start=False)
    with pytest.raises(MediaDownloadError):
        manager._prepare_output_directory(job, "ABC")
    if kind == "file":
        assert destination.read_bytes() == b"existing user bytes"
    else:
        assert destination.is_symlink()
        assert list(external.iterdir()) == [] if external.exists() else True


def test_saved_native_folder_is_checked_without_rediscovery(manager, monkeypatch, tmp_path):
    job = manager.create_job(SOURCES[9][2], cookie_browser=None, auto_start=False)
    external = tmp_path / "unrelated"
    external.mkdir()
    saved = tmp_path / "selected" / "ABC"
    saved.symlink_to(external, target_is_directory=True)
    manager._jobs[job.id].output_dir = str(saved)
    manager._run_job(job.id, [], False, threading.Event())
    failed = manager.get_job(job.id)
    assert failed.status == JobStatus.FAILED
    assert "safe direct child" in failed.error
    assert saved.is_symlink()
    assert list(external.iterdir()) == []


def kuaishou_result(author="ABC", *, complete=True, kind="profile", count=2):
    videos = [ks.parse_video({
        "photo": {"id": f"3xvideo{index}", "caption": "Fixture video", "duration": 5000,
                  "timestamp": 1_720_000_000_000, "photoUrl": "https://v1.kwaicdn.com/upic/fixture.mp4"},
        "author": {"id": "3xowner1", "name": author},
    }) for index in range(1, count + 1)]
    return ks.Result(videos, kind, "3xowner1" if kind == "profile" else "3xvideo1", complete=complete)


@pytest.mark.parametrize("kind", ["profile", "item"])
@pytest.mark.parametrize("legacy", [False, True])
def test_real_manager_preserves_directory_and_completed_files_after_rediscovery(
    monkeypatch, tmp_path, kind, legacy
):
    """Run actual Kuaishou discovery adaptation and persistence; media is synthetic."""
    state_dir = tmp_path / "state"
    root = tmp_path / "selected"
    manager = DownloadManager(
        state_dir=state_dir, default_output_root=root,
        new_job_output_layout=OutputLayout.PLATFORM_AUTHOR if legacy else OutputLayout.AUTHOR,
    )
    result = kuaishou_result(kind=kind, complete=False, count=2 if kind == "profile" else 1)
    monkeypatch.setattr(engine, "discover_kuaishou", lambda *args, **kwargs: result)
    calls = []

    def download(self, item, platform, output_dir, **kwargs):
        calls.append((item.media_id, Path(output_dir)))
        output = Path(output_dir) / f"{item.media_id}.mp4"
        output.write_bytes(f"synthetic {item.media_id}".encode())
        return engine.DownloadOutcome(output_paths=[str(output)], media_type=MediaType.VIDEO)

    monkeypatch.setattr(engine.MediaDownloader, "download_item", download)
    try:
        job = manager.create_job(SOURCES[4 if kind == "profile" else 5][2], cookie_browser=None, auto_start=False)
        manager._run_job(job.id, None, True, threading.Event())
        saved = manager.get_job(job.id)
        expected = root / "Kuaishou" / "ABC" if legacy else root / "ABC"
        assert saved.output_dir == str(expected)
        assert all(item.status == ItemStatus.COMPLETED for item in saved.items)
        original_paths = [Path(item.output_paths[0]) for item in saved.items]
        original_bytes = [path.read_bytes() for path in original_paths]
        original_calls = len(calls)
    finally:
        manager.shutdown()

    if legacy:
        # Simulate a pre-feature record which has no policy field at all.
        state = state_dir / f"{job.id}.json"
        payload = json.loads(state.read_text())
        payload.pop("output_layout")
        state.write_text(json.dumps(payload))
    result = kuaishou_result("Renamed Author", kind=kind, count=2 if kind == "profile" else 1)
    restored = DownloadManager(state_dir=state_dir, default_output_root=tmp_path / "different-new-root")
    helper.configure_download_layout(SimpleNamespace(manager=restored))
    try:
        restored._run_job(job.id, None, True, threading.Event())
        final = restored.get_job(job.id)
        assert final.status == JobStatus.COMPLETED
        assert final.output_dir == str(expected)
        assert [Path(item.output_paths[0]) for item in final.items] == original_paths
        assert [path.read_bytes() for path in original_paths] == original_bytes
        assert len(calls) == original_calls
        assert not (root / "Renamed Author").exists()
        assert not (root / "Kuaishou" / "Renamed Author").exists()
        assert restored.store.get(job.id).output_dir == str(expected)
        assert final.output_layout == (OutputLayout.PLATFORM_AUTHOR if legacy else OutputLayout.AUTHOR)
    finally:
        restored.shutdown()


def test_layout_is_bound_when_task_is_created_and_validated_on_load(manager):
    job = manager.create_job(SOURCES[5][2], cookie_browser=None, auto_start=False)
    manager.new_job_output_layout = OutputLayout.PLATFORM_AUTHOR
    persisted = manager.store.get(job.id)
    assert persisted.output_layout == OutputLayout.AUTHOR
    payload = persisted.model_dump()
    payload["output_layout"] = "../invalid"
    with pytest.raises(ValueError):
        DownloadJob.model_validate(payload)


@pytest.mark.parametrize("legacy", [False, True])
def test_partial_task_restarts_and_retries_only_failed_work_in_original_folder(
    monkeypatch, tmp_path, legacy
):
    state_dir = tmp_path / "state"
    root = tmp_path / "selected"
    result = kuaishou_result()
    monkeypatch.setattr(engine, "discover_kuaishou", lambda *args, **kwargs: result)
    attempts = {}

    def download(self, item, platform, output_dir, **kwargs):
        attempts[item.media_id] = attempts.get(item.media_id, 0) + 1
        if item.media_id == "3xvideo2" and attempts[item.media_id] == 1:
            raise MediaDownloadError("Fixture media transfer was interrupted")
        path = Path(output_dir) / f"{item.media_id}.mp4"
        with path.open("xb") as stream:
            stream.write(f"synthetic {item.media_id}".encode())
        return engine.DownloadOutcome(output_paths=[str(path)], media_type=MediaType.VIDEO)

    monkeypatch.setattr(engine.MediaDownloader, "download_item", download)
    first = DownloadManager(
        state_dir=state_dir, default_output_root=root,
        new_job_output_layout=OutputLayout.PLATFORM_AUTHOR if legacy else OutputLayout.AUTHOR,
    )
    try:
        created = first.create_job(SOURCES[4][2], cookie_browser=None, auto_start=False)
        first._run_job(created.id, None, True, threading.Event())
        partial = first.get_job(created.id)
        assert partial.status == JobStatus.PARTIAL
        assert [item.status for item in partial.items] == [ItemStatus.COMPLETED, ItemStatus.FAILED]
        completed_path = Path(partial.items[0].output_paths[0])
        original_stat = completed_path.stat()
    finally:
        first.shutdown()

    result = kuaishou_result("Renamed Author")
    restarted = DownloadManager(state_dir=state_dir, default_output_root=tmp_path / "new-selection")
    helper.configure_download_layout(SimpleNamespace(manager=restarted))
    try:
        restarted.retry_failed(created.id)
        restarted._futures[created.id].result(timeout=5)
        completed = restarted.get_job(created.id)
        assert completed.status == JobStatus.COMPLETED
        assert completed.output_dir == partial.output_dir
        assert completed.output_root == partial.output_root
        assert attempts == {"3xvideo1": 1, "3xvideo2": 2}
        assert completed_path.read_bytes() == b"synthetic 3xvideo1"
        assert completed_path.stat().st_ino == original_stat.st_ino
        assert completed_path.stat().st_mtime_ns == original_stat.st_mtime_ns
        assert all(Path(item.output_paths[0]).parent == Path(partial.output_dir) for item in completed.items)
    finally:
        restarted.shutdown()
