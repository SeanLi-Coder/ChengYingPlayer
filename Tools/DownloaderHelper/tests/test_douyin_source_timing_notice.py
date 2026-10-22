"""Numeric original-source timing notices, with synthetic state and no accounts."""

from __future__ import annotations

import importlib
import json
import math
import shutil
import socket
import subprocess
import sys
import threading
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "vendor/rednote"))

import helper
from app.downloader import DownloaderConfig, DownloadOutcome, EngineEvent
from app.models import (
    DownloadItem,
    DownloadJob,
    ItemStatus,
    JobStatus,
    MediaType,
    Platform,
    SourceKind,
    SourceTiming,
    normalized_source_timing,
)
from app.storage import JsonJobStore
from app.task_manager import DownloadManager

TIMING = {
    "declared_duration": 50.804,
    "video_duration": 10.033333,
    "audio_duration": 50.803810,
    "container_duration": 50.803991,
}
SOURCE = "https://www.douyin.com/video/1234567890123456789"
PROFILE = "https://www.douyin.com/user/fixture-author"


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    def forbidden(*args, **kwargs):
        raise AssertionError("Network and DNS are forbidden in timing notice tests")

    monkeypatch.setattr(socket.socket, "connect", forbidden)
    monkeypatch.setattr(socket, "create_connection", forbidden)
    monkeypatch.setattr(socket, "getaddrinfo", forbidden)


def item(**kwargs):
    return DownloadItem(
        id="fixture", media_id="1234567890123456789", source_url=SOURCE,
        media_type=MediaType.VIDEO, **kwargs,
    )


def job(tmp_path, **kwargs):
    return DownloadJob(
        id="fixture", source_url=PROFILE, platform=Platform.DOUYIN,
        source_kind=SourceKind.PROFILE, output_root=str(tmp_path / "output"),
        cookie_browser=None, **kwargs,
    )


@pytest.fixture
def manager(tmp_path):
    value = DownloadManager(
        state_dir=tmp_path / "state", default_output_root=tmp_path / "output",
    )
    try:
        yield value
    finally:
        value.shutdown(wait=True, cancel_running=True)


def register(manager, record):
    manager._jobs[record.id] = record
    manager.store.save(record)


@pytest.mark.parametrize("field", tuple(TIMING))
@pytest.mark.parametrize("invalid", [0, -1, math.nan, math.inf, -math.inf, True, "50.804", None, {}, []])
def test_invalid_numeric_notice_does_not_discard_job(tmp_path, field, invalid):
    raw = {**TIMING, field: invalid}
    candidate = item(status=ItemStatus.COMPLETED, source_timing=raw)
    assert candidate.source_timing is None
    saved = job(tmp_path, status=JobStatus.COMPLETED, items=[candidate])
    store = JsonJobStore(tmp_path / "state")
    store.save(saved)
    recovered = store.get(saved.id)
    assert recovered.items[0].status == ItemStatus.COMPLETED
    assert recovered.items[0].source_timing is None


@pytest.mark.parametrize("raw", [
    {}, {"video_duration": 10}, {**TIMING, "url": "https://private.invalid/SECRET"},
    "SECRET", [TIMING], None,
])
def test_notice_rejects_missing_and_unknown_fields(raw):
    assert normalized_source_timing(raw) is None


def test_valid_notice_survives_storage_restart_and_completed_rediscovery(tmp_path, manager):
    completed = item(status=ItemStatus.COMPLETED, source_timing=TIMING,
                     output_paths=[str(tmp_path / "fixture.mp4")], resolution="1080x1920")
    record = job(tmp_path, status=JobStatus.COMPLETED, items=[completed])
    register(manager, record)
    restored = manager.store.get(record.id)
    assert restored.items[0].source_timing.model_dump() == TIMING
    fresh = item(extractor_key="Douyin")
    merged = manager._merge_discovered_items(restored.items, [fresh])
    assert merged[0].source_timing.model_dump() == TIMING
    assert merged[0].output_paths == completed.output_paths
    assert merged[0].resolution == "1080x1920"
    manager.shutdown(wait=True, cancel_running=True)
    restarted = DownloadManager(state_dir=tmp_path / "state", default_output_root=tmp_path / "output")
    try:
        recovered = restarted.get_job(record.id)
        assert recovered.items[0].source_timing.model_dump() == TIMING
    finally:
        restarted.shutdown()


def test_legacy_item_has_no_notice_and_reset_clears_only_notice():
    legacy = item(output_paths=["fixture.mp4"], resolution="1080x1920")
    assert legacy.source_timing is None
    legacy.source_timing = normalized_source_timing(TIMING)
    DownloadManager._reset_item(legacy)
    assert legacy.source_timing is None
    assert legacy.output_paths == ["fixture.mp4"]
    assert legacy.resolution == "1080x1920"


def test_unfinished_rediscovery_drops_stale_notice():
    old = item(status=ItemStatus.FAILED, source_timing=TIMING)
    fresh = item(extractor_key="Douyin")
    merged = DownloadManager._merge_discovered_items([old], [fresh])
    assert merged[0].source_timing is None
    assert old.source_timing.model_dump() == TIMING


@pytest.mark.parametrize("event_type", ["metadata", "probing", "downloading", "warning", "completed"])
def test_only_completed_engine_event_persists_notice(manager, tmp_path, event_type):
    record = job(tmp_path, items=[item()])
    register(manager, record)
    manager._on_engine_event(record.id, "fixture", EngineEvent(event=event_type, source_timing=TIMING))
    actual = manager.get_job(record.id).items[0].source_timing
    assert (actual.model_dump() if actual else None) == (TIMING if event_type == "completed" else None)
    if event_type == "completed":
        assert manager.store.get(record.id).items[0].source_timing.model_dump() == TIMING


@pytest.mark.parametrize("timing", [TIMING, None, {**TIMING, "secret": "PRIVATE"}])
def test_actual_manager_success_propagates_only_safe_outcome(manager, tmp_path, monkeypatch, timing):
    record = job(tmp_path, items=[item(source_timing=TIMING)])
    register(manager, record)

    def download_item(snapshot, platform, output_dir, *, callback, should_cancel):
        assert snapshot.source_timing is None
        assert not should_cancel()
        return DownloadOutcome(
            output_paths=[str(output_dir / "fixture.mp4")], media_type=MediaType.VIDEO,
            resolution="1080x1920", source_timing=timing,
        )

    monkeypatch.setattr(manager, "_engine_for_job", lambda _: SimpleNamespace(download_item=download_item))
    manager._run_job(record.id, ["fixture"], False, threading.Event())
    completed = manager.store.get(record.id)
    assert completed.items[0].status == ItemStatus.COMPLETED
    actual = completed.items[0].source_timing
    assert (actual.model_dump() if actual else None) == (TIMING if timing == TIMING else None)
    assert completed.items[0].resolution == "1080x1920"


def test_native_opt_in_is_not_standalone_default(manager):
    assert DownloaderConfig().allow_douyin_unequal_tracks is False
    helper.configure_download_layout(SimpleNamespace(manager=manager))
    assert manager.downloader_config.allow_douyin_unequal_tracks is True


@pytest.fixture
def public_main(tmp_path, monkeypatch):
    monkeypatch.setenv("CHENGYING_DOWNLOAD_DATA_DIR", str(tmp_path / "engine-data"))
    monkeypatch.setenv("CHENGYING_DOWNLOAD_DEFAULT_DIR", str(tmp_path / "engine-output"))
    previous = sys.modules.pop("app.main", None)
    module = importlib.import_module("app.main")
    try:
        yield module
    finally:
        module.manager.shutdown(wait=True, cancel_running=True)
        sys.modules.pop("app.main", None)
        if previous is not None:
            sys.modules["app.main"] = previous


def test_public_response_revalidates_and_never_exposes_extra_fields(public_main, tmp_path):
    original = job(tmp_path, items=[item(status=ItemStatus.COMPLETED, source_timing=TIMING)])
    public = public_main._public_job(original)
    assert public.items[0].source_timing.model_dump() == TIMING
    # Assignment does not itself enforce BaseModel validation in this schema.
    original.items[0].source_timing = {**TIMING, "media_url": "https://private.invalid/SECRET"}
    public = public_main._public_job(original)
    assert public.items[0].source_timing is None
    assert "SECRET" not in public.model_dump_json()
    assert "SECRET" in original.items[0].source_timing["media_url"]


def test_public_response_revalidates_constructed_models(public_main, tmp_path):
    original = job(tmp_path, items=[item()])
    original.items[0].source_timing = SourceTiming.model_construct(**{**TIMING, "audio_duration": math.inf})
    assert public_main._public_job(original).items[0].source_timing is None


def test_non_douyin_notice_is_not_exposed(public_main, tmp_path, manager):
    original = job(tmp_path, items=[item()])
    original.platform = Platform.YOUTUBE
    register(manager, original)
    manager._on_engine_event(original.id, "fixture", EngineEvent(event="completed", source_timing=TIMING))
    assert manager.get_job(original.id).items[0].source_timing is None
    original.items[0].source_timing = normalized_source_timing(TIMING)
    assert public_main._public_job(original).items[0].source_timing is None


def test_frontend_notice_is_numeric_explicit_and_only_for_completed_videos():
    node = shutil.which("node")
    if node is None:
        pytest.skip("Node.js is unavailable")
    source = (ROOT / "vendor/rednote/app/static/app.js").read_text(encoding="utf-8")
    marker = "  initialize();\n})();\n"
    assert source.count(marker) == 1
    source = source.replace(marker, "  window.timingTest = {itemSourceTimingNotice, renderItems};\n})();\n")
    script = "globalThis.window = {}; globalThis.document = {querySelector: () => null};\n" + source
    script += "\nconst base = " + json.dumps({"status": "completed", "media_type": "video", "source_timing": TIMING}) + ";\n"
    script += """
const notice = window.timingTest.itemSourceTimingNotice;
const accepted = notice(base, {platform: 'douyin'});
const rejected = [
  notice({...base, status: 'failed'}, {platform: 'douyin'}),
  notice({...base, status: 'downloading'}, {platform: 'douyin'}),
  notice({...base, media_type: 'image'}, {platform: 'douyin'}),
  notice(base, {platform: 'youtube'}),
  notice({...base, source_timing: null}, {platform: 'douyin'}),
  notice({...base, source_timing: {...base.source_timing, secret: 'PRIVATE'}}, {platform: 'douyin'}),
];
for (const field of Object.keys(base.source_timing)) {
  for (const value of [0, -1, NaN, Infinity, true, '50.804', '<img src=x>', null, undefined]) {
    rejected.push(notice({...base, source_timing: {...base.source_timing, [field]: value}}, {platform: 'douyin'}));
  }
}
process.stdout.write(JSON.stringify({accepted, rejected}));
"""
    result = subprocess.run([node, "-e", script], capture_output=True, text=True, timeout=30, check=False)
    assert result.returncode == 0, result.stderr
    output = json.loads(result.stdout)
    assert output["accepted"] == "网站原样文件：画面 10.033 秒，音频 50.804 秒；音画时长不同，未转码或补帧。"
    assert all(value == "" for value in output["rejected"])
    assert "PRIVATE" not in result.stdout


def test_frontend_render_refreshes_notice_without_html_or_stale_rows():
    node = shutil.which("node")
    if node is None:
        pytest.skip("Node.js is unavailable")
    source = (ROOT / "vendor/rednote/app/static/app.js").read_text(encoding="utf-8")
    marker = "  initialize();\n})();\n"
    assert source.count(marker) == 1
    source = source.replace(marker, "  window.timingTest = {renderItems};\n})();\n")
    script = r"""
class Element {
  constructor(tag = 'div') {
    this.tag = tag;
    this.children = [];
    this.selectors = new Map();
    this.classList = {add() {}};
    this.style = {};
    this.textContent = '';
  }
  set innerHTML(value) {throw new Error('HTML injection is not allowed');}
  querySelector(selector) {
    if (!this.selectors.has(selector)) {
      const child = new Element();
      child.parent = this;
      this.selectors.set(selector, child);
      this.children.push(child);
    }
    return this.selectors.get(selector);
  }
  after(child) {this.parent.children.push(child);}
  append(child) {this.children.push(child);}
  replaceChildren() {this.children = [];}
  setAttribute() {}
  addEventListener() {}
  cloneNode() {return new Element('article');}
}
const elements = new Map();
globalThis.window = {};
globalThis.document = {
  querySelector(selector) {
    if (!elements.has(selector)) elements.set(selector, new Element());
    return elements.get(selector);
  },
  createElement: (tag) => new Element(tag),
  createDocumentFragment: () => new Element('fragment'),
};
document.querySelector('#item-template').content = {firstElementChild: new Element()};
function notices(element) {
  return [
    ...(element.className === 'item-source-timing' ? [element.textContent] : []),
    ...element.children.flatMap(notices),
  ];
}
""" + source
    script += "\nconst timing = " + json.dumps(TIMING) + ";\n"
    script += """
const work = {id: 'fixture', status: 'completed', media_type: 'video', title: 'Fixture',
  source_url: 'https://www.douyin.com/video/1234567890123456789', source_timing: timing};
const job = {id: 'job', platform: 'douyin', status: 'completed', items: [work]};
const snapshots = [];
const capture = () => {
  window.timingTest.renderItems(job);
  snapshots.push(notices(document.querySelector('#items-list')));
};
capture();
work.status = 'downloading'; capture();
work.status = 'completed'; work.source_timing = null; capture();
work.source_timing = timing; capture();
work.source_timing = {...timing, video_duration: '<img src=x onerror=alert(1)>'}; capture();
process.stdout.write(JSON.stringify(snapshots));
"""
    result = subprocess.run([node, "-e", script], capture_output=True, text=True, timeout=30, check=False)
    assert result.returncode == 0, result.stderr
    snapshots = json.loads(result.stdout)
    expected = "网站原样文件：画面 10.033 秒，音频 50.804 秒；音画时长不同，未转码或补帧。"
    assert snapshots == [[expected], [], [], [expected], []]

