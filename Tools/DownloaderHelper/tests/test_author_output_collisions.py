"""Native author-folder publication regressions using isolated synthetic files."""

from __future__ import annotations

import errno
import io
import shutil
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "vendor/rednote"))

from app import downloader as engine
from app.errors import DownloadCancelledError, MediaDownloadError
from app.models import DownloadItem, MediaType, Platform
from app.xiaohongshu import RemoteAsset
from test_kuaishou import MEDIA, VIDEO, make_real_mp4


def native_downloader():
    return engine.MediaDownloader(
        engine.DownloaderConfig(cookie_browser=None, preserve_existing_files=True)
    )


def publish(downloader, source, target, *, should_cancel=lambda: False):
    return downloader._publish_download(source, target, should_cancel=should_cancel)


def test_publication_preserves_an_existing_file_and_its_identity(tmp_path):
    old = tmp_path / "Fixture.mp4"
    old.write_bytes(b"original user bytes")
    original = old.stat()
    incoming = tmp_path / ".incoming.part"
    incoming.write_bytes(b"new verified bytes")
    saved = publish(native_downloader(), incoming, old)
    assert saved != old
    assert saved.parent == tmp_path
    assert saved.read_bytes() == b"new verified bytes"
    assert old.read_bytes() == b"original user bytes"
    assert old.stat().st_ino == original.st_ino
    assert old.stat().st_mtime_ns == original.st_mtime_ns
    assert not incoming.exists()


@pytest.mark.parametrize("dangling", [False, True])
def test_existing_final_symlink_is_neither_followed_nor_replaced(tmp_path, dangling):
    outside = tmp_path / "outside.mp4"
    if not dangling:
        outside.write_bytes(b"unrelated original")
    output = tmp_path / "ABC"
    output.mkdir()
    target = output / "Fixture.mp4"
    target.symlink_to(outside)
    incoming = output / ".incoming.part"
    incoming.write_bytes(b"new verified bytes")
    saved = publish(native_downloader(), incoming, target)
    assert target.is_symlink()
    assert saved != target
    assert saved.parent == output
    assert saved.read_bytes() == b"new verified bytes"
    if dangling:
        assert not outside.exists()
    else:
        assert outside.read_bytes() == b"unrelated original"


@pytest.mark.parametrize("stem", ["a" * 251, "汉" * 82 + "abcde"])
def test_collision_suffix_respects_utf8_component_limit(tmp_path, stem):
    target = tmp_path / f"{stem}.mp4"
    assert len(target.name.encode("utf-8")) == 255
    target.write_bytes(b"original")
    incoming = tmp_path / ".incoming.part"
    incoming.write_bytes(b"replacement")
    saved = publish(native_downloader(), incoming, target)
    assert saved != target
    assert saved.suffix == ".mp4"
    assert len(saved.name.encode("utf-8")) <= 255
    assert saved.read_bytes() == b"replacement"
    assert target.read_bytes() == b"original"


def test_concurrent_publishers_do_not_replace_each_other(tmp_path):
    target = tmp_path / "Fixture.mp4"
    target.write_bytes(b"original")
    count = 8
    gate = threading.Barrier(count)
    sources = []
    for index in range(count):
        source = tmp_path / f".incoming-{index}.part"
        source.write_bytes(f"new media {index}".encode())
        sources.append(source)

    def transfer(source):
        gate.wait(timeout=10)
        return publish(native_downloader(), source, target)

    with ThreadPoolExecutor(max_workers=count) as executor:
        results = list(executor.map(transfer, sources))
    assert len(set(results)) == count
    assert {path.read_bytes() for path in results} == {
        f"new media {index}".encode() for index in range(count)
    }
    assert target.read_bytes() == b"original"
    assert not list(tmp_path.glob("*.part"))


def test_cancel_before_publication_preserves_both_original_and_staged_bytes(tmp_path):
    target = tmp_path / "Fixture.mp4"
    target.write_bytes(b"original")
    incoming = tmp_path / ".incoming.part"
    incoming.write_bytes(b"new bytes")
    with pytest.raises(DownloadCancelledError):
        publish(native_downloader(), incoming, target, should_cancel=lambda: True)
    assert target.read_bytes() == b"original"
    assert incoming.read_bytes() == b"new bytes"
    assert sorted(path.name for path in tmp_path.iterdir()) == [
        ".incoming.part", "Fixture.mp4",
    ]


@pytest.mark.parametrize("error_code", [errno.ENOSPC, errno.EACCES])
def test_noncollision_failures_are_redacted_and_not_retried(monkeypatch, tmp_path, error_code):
    target = tmp_path / "private-destination.mp4"
    incoming = tmp_path / ".private-source.part"
    incoming.write_bytes(b"staged bytes")
    calls = []

    def denied_link(source, destination, **kwargs):
        calls.append((source, destination))
        raise OSError(error_code, "Synthetic filesystem failure", str(source), None, str(destination))

    monkeypatch.setattr(engine.sys, "platform", "linux")
    monkeypatch.setattr(engine.os, "link", denied_link)
    with pytest.raises(MediaDownloadError) as caught:
        publish(native_downloader(), incoming, target)
    assert len(calls) == 1
    assert str(incoming) not in str(caught.value)
    assert str(target) not in str(caught.value)
    assert incoming.name not in str(caught.value)
    assert caught.value.__cause__.errno == error_code
    assert incoming.read_bytes() == b"staged bytes"
    assert not target.exists()


def fake_ytdlp(monkeypatch, *, name, payload=b"new media", escape=None, symlink=None):
    observed = []

    class FixtureYoutubeDL:
        def __init__(self, options):
            self.options = options
            observed.append(options)

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return None

        def add_post_processor(self, post_processor, when):
            self.processor = post_processor

        def extract_info(self, url, download):
            assert download
            output = Path(self.options["paths"]["home"])
            output.mkdir(parents=True, exist_ok=True)
            path = output / name
            if escape is not None:
                path = escape
            elif symlink is not None:
                path.symlink_to(symlink)
            else:
                path.write_bytes(payload)
            info = {
                "id": "abc123", "title": "Fixture", "upload_date": "20260930",
                "uploader": "ABC", "vcodec": "h264", "width": 320, "height": 180,
                "filepath": str(path),
                "requested_downloads": [{"filepath": str(path)}],
            }
            for hook in self.options["post_hooks"]:
                hook(str(path))
            return info

        def prepare_filename(self, info):
            return info["filepath"]

    monkeypatch.setattr(engine, "YoutubeDL", FixtureYoutubeDL)
    return observed


def generic_item():
    return DownloadItem(
        id="fixture", media_id="abc123", source_url="https://www.youtube.com/watch?v=abc123",
        metadata={"_job_id": "synthetic-task"},
    )


@pytest.mark.parametrize("platform", [Platform.YOUTUBE, Platform.BILIBILI])
def test_generic_output_is_staged_then_published_without_clobbering(monkeypatch, tmp_path, platform):
    name = "2026-09-30-Fixture [abc123].mp4"
    existing = tmp_path / name
    existing.write_bytes(b"existing Kuaishou or user file")
    options = fake_ytdlp(monkeypatch, name=name)
    outcome = native_downloader().download_item(generic_item(), platform, tmp_path)
    assert Path(options[0]["paths"]["home"]).is_relative_to(tmp_path / ".parts")
    assert len(outcome.output_paths) == 1
    saved = Path(outcome.output_paths[0])
    assert saved.parent == tmp_path
    assert saved != existing
    assert saved.read_bytes() == b"new media"
    assert existing.read_bytes() == b"existing Kuaishou or user file"
    assert not (tmp_path / ".parts").exists()


@pytest.mark.parametrize("mode", ["escape", "symlink"])
def test_generic_completion_rejects_files_outside_its_private_stage(monkeypatch, tmp_path, mode):
    output = tmp_path / "ABC"
    output.mkdir()
    outside = tmp_path / "unrelated.mp4"
    outside.write_bytes(b"unrelated user file")
    fake_ytdlp(monkeypatch, name="Fixture.mp4", **{mode: outside})
    with pytest.raises(MediaDownloadError):
        native_downloader().download_item(generic_item(), Platform.YOUTUBE, output)
    assert outside.read_bytes() == b"unrelated user file"
    assert not list(output.glob("*.mp4"))


def test_cancelled_generic_transfer_retains_only_private_retry_data(monkeypatch, tmp_path):
    name = "2026-09-30-Fixture [abc123].mp4"
    target = tmp_path / name
    target.write_bytes(b"original user file")
    options = fake_ytdlp(monkeypatch, name=name)
    original_extract = engine.YoutubeDL.extract_info
    attempts = 0

    def interrupted_extract(self, url, download):
        nonlocal attempts
        attempts += 1
        result = original_extract(self, url, download)
        if attempts == 1:
            raise DownloadCancelledError("Synthetic cancellation before publication")
        return result

    monkeypatch.setattr(engine.YoutubeDL, "extract_info", interrupted_extract)
    with pytest.raises(DownloadCancelledError):
        native_downloader().download_item(generic_item(), Platform.YOUTUBE, tmp_path)
    assert target.read_bytes() == b"original user file"
    assert list(tmp_path.glob("*.mp4")) == [target]
    private_output = Path(options[0]["paths"]["home"]) / name
    assert private_output.is_relative_to(tmp_path / ".parts")
    assert private_output.read_bytes() == b"new media"
    outcome = native_downloader().download_item(generic_item(), Platform.YOUTUBE, tmp_path)
    assert len(outcome.output_paths) == 1
    saved = Path(outcome.output_paths[0])
    assert saved.parent == tmp_path and saved != target
    assert saved.read_bytes() == b"new media"
    assert target.read_bytes() == b"original user file"
    assert all(value["continuedl"] is True for value in options)
    assert not (tmp_path / ".parts").exists()


@pytest.fixture
def video_payload(tmp_path):
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        pytest.skip("Synthetic video transfer tests require FFmpeg and FFprobe")
    source = tmp_path / "source"
    source.mkdir()
    return make_real_mp4(source, 320, 180).read_bytes()


def transfer_video(monkeypatch, downloader, output, payload, *, title, platform=Platform.KUAISHOU):
    def open_response(ydl, request, *, is_trusted_url):
        response = io.BytesIO(payload)
        response.url = request.url
        response.headers = {"Content-Type": "video/mp4", "Content-Length": str(len(payload))}
        return response

    monkeypatch.setattr(engine, "_open_xiaohongshu_response", open_response)
    return downloader._download_first_available_asset(
        None,
        [RemoteAsset([MEDIA], 1, width=320, height=180, video_codec="h264", duration=1)],
        output, "2026-09-30", title, "3xfixture", VIDEO,
        platform=platform, media_type=MediaType.VIDEO,
        callback=None, should_cancel=lambda: False, verify_declared_dimensions=True,
    )[0]


def test_real_kuaishou_transfer_then_generic_collision_preserves_both(monkeypatch, tmp_path, video_payload):
    output = tmp_path / "ABC"
    output.mkdir()
    first = transfer_video(
        monkeypatch, native_downloader(), output, video_payload, title="Fixture [abc123]",
    )
    assert first.name == "2026-09-30-Fixture [abc123].mp4"
    fake_ytdlp(monkeypatch, name=first.name, payload=b"different platform media")
    outcome = native_downloader().download_item(generic_item(), Platform.YOUTUBE, output)
    assert first.read_bytes() == video_payload
    assert len(outcome.output_paths) == 1
    second = Path(outcome.output_paths[0])
    assert second != first
    assert second.read_bytes() == b"different platform media"


def test_real_transfer_handles_a_collision_created_during_verification(monkeypatch, tmp_path, video_payload):
    output = tmp_path / "ABC"
    output.mkdir()
    target = output / "2026-09-30-Fixture.mp4"
    instance = native_downloader()
    verify = instance._verify_local_video_asset

    def verify_and_publish_competitor(*args, **kwargs):
        result = verify(*args, **kwargs)
        assert not target.exists()
        target.write_bytes(b"concurrent verified download")
        return result

    monkeypatch.setattr(instance, "_verify_local_video_asset", verify_and_publish_competitor)
    saved = transfer_video(monkeypatch, instance, output, video_payload, title="Fixture")
    assert saved != target
    assert saved.read_bytes() == video_payload
    assert target.read_bytes() == b"concurrent verified download"
    assert not list(output.glob("*.part"))


def test_verified_probe_reuse_also_preserves_existing_files(monkeypatch, tmp_path):
    instance = native_downloader()
    target = tmp_path / "2026-09-30-Fixture [abc123].mp4"
    target.write_bytes(b"existing media")
    probe = tmp_path / ".verified-probe.part"
    probe.write_bytes(b"new verified probe bytes")
    asset = RemoteAsset([MEDIA], 1, width=320, height=180)
    monkeypatch.setattr(instance, "_verify_local_video_asset", lambda *a, **k: asset)
    saved, chosen = instance._reuse_verified_douyin_probe_file(
        probe, asset, tmp_path, "2026-09-30", "Fixture", "abc123",
        callback=None, should_cancel=lambda: False, asset_index=None,
        progress_index=None, progress_count=None,
    )
    assert chosen is asset
    assert saved != target
    assert saved.read_bytes() == b"new verified probe bytes"
    assert target.read_bytes() == b"existing media"
    assert not probe.exists()
