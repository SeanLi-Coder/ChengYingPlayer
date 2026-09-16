from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host import COOKIE_NAME, install_desktop_adapter, resolve_output

TOKEN = "test-desktop-session-" + "x" * 48
ORIGIN = "http://127.0.0.1:51923"


@pytest.fixture
def client(tmp_path):
    app = FastAPI()

    @app.get("/api/health")
    def health():
        return {"status": "ok"}

    engine = SimpleNamespace(
        app=app,
        index=lambda: HTMLResponse(
            "<html><head><title>原迹下载器</title></head></html>"
        ),
        manager=SimpleNamespace(get_job=lambda _: None),
    )
    install_desktop_adapter(engine, token=TOKEN, origin=ORIGIN, assets=tmp_path)
    return TestClient(app, base_url=ORIGIN)


@pytest.mark.parametrize(
    "path",
    [
        "/",
        "/api/health",
        "/api/jobs",
        "/api/events",
        "/native/desktop.js",
        "/static/app.js",
    ],
)
def test_every_route_requires_session(client, path):
    assert client.get(path).status_code == 403
    assert (
        client.get(path, headers={"Cookie": f"{COOKIE_NAME}=wrong"}).status_code == 403
    )


@pytest.mark.parametrize(
    "headers",
    [
        {"Origin": "http://example.invalid"},
        {"Origin": "null"},
        {"Origin": "http://127.0.0.1:51924"},
        {"Host": "localhost:51923"},
        {"Host": "127.0.0.1:51924"},
        {"Referer": "https://example.invalid/a"},
        {"Sec-Fetch-Site": "cross-site"},
        {"Sec-Fetch-Site": "same-site"},
    ],
)
def test_cookie_alone_does_not_allow_cross_origin(client, headers):
    headers["Cookie"] = f"{COOKIE_NAME}={TOKEN}"
    assert client.get("/api/health", headers=headers).status_code == 403


def test_duplicate_sensitive_headers_rejected(client):
    response = client.get(
        "/api/health",
        headers=[
            ("Cookie", f"{COOKIE_NAME}={TOKEN}"),
            ("Origin", ORIGIN),
            ("Origin", ORIGIN),
        ],
    )
    assert response.status_code == 403


def test_authenticated_page_includes_only_desktop_additions(client):
    response = client.get(
        "/", headers={"Cookie": f"{COOKIE_NAME}={TOKEN}", "Origin": ORIGIN}
    )
    assert response.status_code == 200
    assert "澄影 · 下载中心" in response.text
    assert "/native/desktop.js" in response.text
    assert TOKEN not in response.text
    assert "frame-ancestors 'none'" in response.headers["content-security-policy"]
    assert response.headers["referrer-policy"] == "no-referrer"
    assert response.headers["x-content-type-options"] == "nosniff"


def test_native_session_request_without_origin_is_allowed(client):
    response = client.get("/api/health", headers={"Cookie": f"{COOKIE_NAME}={TOKEN}"})
    assert response.status_code == 200


def test_docs_are_not_exposed(client):
    assert (
        client.get(
            "/openapi.json", headers={"Cookie": f"{COOKIE_NAME}={TOKEN}"}
        ).status_code
        == 404
    )


def manager_for(root, outputs, status="completed"):
    item = SimpleNamespace(id="item-1", status=status, output_paths=outputs)
    job = SimpleNamespace(items=[item], output_root=str(root))
    return SimpleNamespace(
        get_job=lambda job_id: (
            job if job_id == "job-1" else (_ for _ in ()).throw(KeyError())
        )
    )


@pytest.mark.parametrize(
    "extension,kind",
    [("mp4", "video"), ("webm", "video"), ("png", "image"), ("heic", "image")],
)
def test_only_recorded_completed_media_can_be_opened(tmp_path, extension, kind):
    output = tmp_path / f"media.{extension}"
    output.touch()
    manager = manager_for(tmp_path, [str(output)])
    assert resolve_output(manager, "job-1", "item-1", 0) == {
        "path": str(output),
        "media_type": kind,
    }


@pytest.mark.parametrize(
    "status", ["downloading", "failed", "cancelled", "queued", "skipped"]
)
def test_incomplete_outputs_are_not_opened(tmp_path, status):
    output = tmp_path / "partial.mp4"
    output.touch()
    with pytest.raises(HTTPException):
        resolve_output(
            manager_for(tmp_path, [str(output)], status), "job-1", "item-1", 0
        )


@pytest.mark.parametrize(
    "job,item,index",
    [
        ("unknown", "item-1", 0),
        ("job-1", "unknown", 0),
        ("job-1", "item-1", -1),
        ("job-1", "item-1", 3),
    ],
)
def test_unknown_output_selection_fails_closed(tmp_path, job, item, index):
    with pytest.raises(HTTPException):
        resolve_output(manager_for(tmp_path, []), job, item, index)


def test_symlink_escape_and_arbitrary_files_rejected(tmp_path):
    root = tmp_path / "downloads"
    root.mkdir()
    private = tmp_path / "private.mp4"
    private.touch()
    link = root / "escape.mp4"
    link.symlink_to(private)
    for path in (private, link, root, root / "missing.mp4", Path("relative.mp4")):
        with pytest.raises(HTTPException):
            resolve_output(manager_for(root, [str(path)]), "job-1", "item-1", 0)
    executable = root / "evil.command"
    executable.touch()
    with pytest.raises(HTTPException):
        resolve_output(manager_for(root, [str(executable)]), "job-1", "item-1", 0)


def test_symlink_inside_download_directory_remains_usable(tmp_path):
    output = tmp_path / "original.mp4"
    output.touch()
    link = tmp_path / "linked.mp4"
    link.symlink_to(output)
    assert resolve_output(manager_for(tmp_path, [str(link)]), "job-1", "item-1", 0)[
        "path"
    ] == str(output)
