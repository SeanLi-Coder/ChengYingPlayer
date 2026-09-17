"""Atomic update admission around the unchanged upstream download manager."""

from __future__ import annotations

import functools
import threading
import time

from fastapi import HTTPException
from fastapi.responses import JSONResponse


class UpdateMaintenance:
    def __init__(self, manager):
        self.manager = manager
        self.lock = getattr(manager, "_lock", threading.RLock())
        self.supported = hasattr(manager, "_futures") and all(
            callable(getattr(manager, name, None))
            for name in ("create_job", "start_job", "retry_item", "retry_failed")
        )
        self.lease = None
        self.deadline = 0.0
        self.released = set()
        self.mutations = 0
        if self.supported:
            for name in ("create_job", "start_job", "retry_item", "retry_failed"):
                original = getattr(manager, name)

                @functools.wraps(original)
                def guarded(*args, _original=original, **kwargs):
                    with self.lock:
                        self.require_admission()
                        return _original(*args, **kwargs)

                setattr(manager, name, guarded)

    def _expire(self):
        # Lost native responses cannot leave downloads disabled indefinitely.
        # Installation is only authorized after this helper has actually exited.
        if self.lease is not None and time.monotonic() >= self.deadline:
            self.released.add(self.lease)
            self.lease = None

    def require_admission(self):
        self._expire()
        if self.lease is not None:
            raise HTTPException(409, "An application update is being prepared. Try again shortly.")

    def _active(self):
        return self.mutations > 0 or any(
            not future.done() for future in self.manager._futures.values()
        )

    def activity(self):
        with self.lock:
            self._expire()
            return {
                "known": self.supported,
                "busy": not self.supported or self._active() or self.lease is not None,
            }

    def acquire(self, identifier):
        with self.lock:
            self._expire()
            if (
                not self.supported
                or identifier in self.released
                or self.lease not in (None, identifier)
                or self._active()
            ):
                return {"acquired": False}
            self.lease = identifier
            self.deadline = time.monotonic() + 60
            return {"acquired": True}

    def release(self, identifier):
        with self.lock:
            # Also veto a delayed acquire request that arrives after cancellation.
            self.released.add(identifier)
            if self.lease == identifier:
                self.lease = None
            return {"released": True}

    def commit(self, identifier):
        with self.lock:
            self._expire()
            if self.lease != identifier or self._active():
                return {"acquired": False}
            # Once EOF is permitted, expiry could let a new worker start while
            # native code is delayed. Keep admission closed until exit/release.
            self.deadline = float("inf")
            return {"acquired": True}


class UpdateMaintenanceMiddleware:
    """Protect all in-flight HTTP mutations, including config and browser actions."""

    def __init__(self, app, *, maintenance):
        self.app = app
        self.maintenance = maintenance

    async def __call__(self, scope, receive, send):
        tracked = (
            scope["type"] == "http"
            and scope.get("method") not in {"GET", "HEAD", "OPTIONS"}
            and not scope.get("path", "").startswith("/api/native/maintenance/")
        )
        if not tracked:
            await self.app(scope, receive, send)
            return
        with self.maintenance.lock:
            try:
                self.maintenance.require_admission()
            except HTTPException:
                blocked = True
            else:
                blocked = False
                self.maintenance.mutations += 1
        if blocked:
            await JSONResponse({"detail": "An application update is being prepared."}, status_code=409)(scope, receive, send)
            return
        try:
            await self.app(scope, receive, send)
        finally:
            with self.maintenance.lock:
                self.maintenance.mutations -= 1
