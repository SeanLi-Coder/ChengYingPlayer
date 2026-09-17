"""Update leases never cancel workers or race queued/retried jobs."""

from __future__ import annotations

import sys
import threading
from concurrent.futures import Future, ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace
from uuid import uuid4

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host import COOKIE_NAME, install_desktop_adapter
from update_maintenance import UpdateMaintenance


class Manager:
    def __init__(self):
        self._lock = threading.RLock()
        self._futures = {}
        self.calls = []
        self.entered = threading.Event()
        self.resume = threading.Event()

    def create_job(self, *, block=False):
        if block:
            self.entered.set()
            assert self.resume.wait(3)
        with self._lock:
            self.calls.append("created")
            self._futures["job"] = Future()

    start_job = create_job
    retry_item = create_job
    retry_failed = create_job


@pytest.mark.parametrize("method", ["create_job", "start_job", "retry_item", "retry_failed"])
def test_lease_blocks_every_submission_before_side_effects(method):
    manager = Manager()
    lease = UpdateMaintenance(manager)
    identifier = str(uuid4())
    assert lease.acquire(identifier) == {"acquired": True}
    with pytest.raises(HTTPException) as error:
        getattr(manager, method)()
    assert error.value.status_code == 409
    assert not manager.calls and not manager._futures
    lease.release(identifier)
    getattr(manager, method)()
    assert manager.calls == ["created"]


def test_active_worker_wins_race_even_when_job_status_is_terminal():
    manager = Manager()
    lease = UpdateMaintenance(manager)
    manager.create_job()
    assert lease.activity() == {"known": True, "busy": True}
    assert lease.acquire(str(uuid4())) == {"acquired": False}
    assert not manager._futures["job"].cancelled()
    manager._futures["job"].set_result(None)
    assert lease.activity() == {"known": True, "busy": False}
    assert lease.acquire(str(uuid4())) == {"acquired": True}


def test_create_before_inner_upstream_lock_cannot_be_overtaken_by_lease():
    manager = Manager()
    lease = UpdateMaintenance(manager)
    with ThreadPoolExecutor(max_workers=2) as executor:
        creation = executor.submit(manager.create_job, block=True)
        assert manager.entered.wait(3)
        acquisition = executor.submit(lease.acquire, str(uuid4()))
        assert not acquisition.done()
        manager.resume.set()
        creation.result(timeout=3)
        assert acquisition.result(timeout=3) == {"acquired": False}


def test_cancelled_request_tombstone_and_lease_identity():
    lease = UpdateMaintenance(Manager())
    old, current = str(uuid4()), str(uuid4())
    lease.release(old)
    assert lease.acquire(old) == {"acquired": False}
    assert lease.acquire(current) == {"acquired": True}
    lease.release(old)
    assert lease.activity()["busy"]
    lease.release(current)
    assert not lease.activity()["busy"]


def test_lost_release_eventually_restores_download_admission():
    manager = Manager()
    lease = UpdateMaintenance(manager)
    identifier = str(uuid4())
    lease.acquire(identifier)
    lease.deadline = 0
    manager.create_job()
    assert manager.calls == ["created"]
    assert lease.acquire(identifier) == {"acquired": False}


def test_unknown_manager_fails_closed():
    lease = UpdateMaintenance(SimpleNamespace())
    assert lease.activity() == {"known": False, "busy": True}
    assert lease.acquire(str(uuid4())) == {"acquired": False}


def test_shutdown_commit_prevents_expiry_from_reopening_admission():
    manager = Manager()
    lease = UpdateMaintenance(manager)
    identifier = str(uuid4())
    assert lease.commit(identifier) == {"acquired": False}
    lease.acquire(identifier)
    assert lease.commit(str(uuid4())) == {"acquired": False}
    assert lease.commit(identifier) == {"acquired": True}
    assert lease.deadline == float("inf")
    with pytest.raises(HTTPException):
        manager.retry_failed()
    lease.release(identifier)
    assert lease.commit(identifier) == {"acquired": False}
    manager.retry_failed()
    assert manager.calls == ["created"]


def test_authenticated_http_admission_and_inflight_mutation(tmp_path):
    manager = Manager()
    app = FastAPI()
    entered, resume = threading.Event(), threading.Event()

    @app.post("/api/test/mutation")
    def mutation():
        entered.set()
        assert resume.wait(3)
        return {"ok": True}

    origin = "http://127.0.0.1:51923"
    token = "update-test-" + "x" * 48
    install_desktop_adapter(SimpleNamespace(app=app, manager=manager), token=token, origin=origin, assets=tmp_path)
    with TestClient(app, base_url=origin) as client:
        assert client.get("/api/native/activity").status_code == 403
        client.cookies.set(COOKIE_NAME, token)
        assert client.get("/api/native/activity").json() == {"known": True, "busy": False}
        identifier = str(uuid4())
        endpoint = f"/api/native/maintenance/{identifier}"
        with ThreadPoolExecutor(max_workers=1) as executor:
            mutation_request = executor.submit(client.post, "/api/test/mutation")
            assert entered.wait(3)
            assert client.get("/api/native/activity").json()["busy"]
            assert client.put(endpoint).json() == {"acquired": False}
            resume.set()
            assert mutation_request.result(timeout=3).status_code == 200
        assert client.put(endpoint).json() == {"acquired": True}
        assert client.put(endpoint + "/commit").json() == {"acquired": True}
        assert client.post("/api/test/mutation").status_code == 409
        assert client.get("/api/native/activity").status_code == 200
        assert client.delete(endpoint).json() == {"released": True}
        assert client.post("/api/test/mutation").status_code == 200
        assert client.put("/api/native/maintenance/not-a-uuid").status_code == 422


def test_real_upstream_manager_cannot_create_records_while_leased(tmp_path):
    vendor = Path(__file__).resolve().parents[1] / "vendor" / "rednote"
    sys.path.insert(0, str(vendor))
    from app.task_manager import DownloadManager

    manager = DownloadManager(state_dir=tmp_path / "state", default_output_root=tmp_path / "output")
    try:
        lease = UpdateMaintenance(manager)
        identifier = str(uuid4())
        assert lease.acquire(identifier) == {"acquired": True}
        with pytest.raises(HTTPException):
            manager.create_job("https://www.youtube.com/watch?v=abcdefghijk", auto_start=False, cookie_browser=None)
        assert manager.list_jobs() == []
        assert list((tmp_path / "output").iterdir()) == []
        lease.release(identifier)
        job = manager.create_job("https://www.youtube.com/watch?v=abcdefghijk", auto_start=False, cookie_browser=None)
        assert len(manager.list_jobs()) == 1 and job.id
        assert not manager._futures
    finally:
        manager.shutdown(wait=True, cancel_running=False)
