"""Use the sealed Playwright Node executable for native yt-dlp EJS challenges."""

from __future__ import annotations

import functools
import importlib
import os
import sys
import threading
from pathlib import Path

_LOCK = threading.RLock()
_installation = None
NODE_VERSION = "24.18.1"


def node_path() -> Path:
    import playwright

    path = (Path(playwright.__file__).resolve().parent / "driver/node").resolve(
        strict=True
    )
    if not path.is_file() or not os.access(path, os.X_OK):
        raise RuntimeError("The bundled Node executable is unavailable")
    if getattr(sys, "frozen", False):
        contents = Path(sys.executable).resolve().parent.parent
        if not path.is_relative_to(contents / "Frameworks"):
            raise RuntimeError(
                "The JavaScript runtime must remain inside the sealed helper"
            )
    return path


def install_js_runtime():
    """Adapt only runtime selection; preserve upstream download/cookie options."""
    global _installation
    with _LOCK:
        if _installation is not None:
            return _installation
        downloader = importlib.import_module("app.downloader").MediaDownloader
        original = downloader._base_options
        runtime = str(node_path())

        @functools.wraps(original)
        def options(self, *args, **kwargs):
            result = dict(original(self, *args, **kwargs))
            result["js_runtimes"] = {"node": {"path": runtime}}
            # Both solver files are already pinned and bundled. No runtime install
            # or remote JavaScript component is needed at application launch.
            result["remote_components"] = []
            return result

        downloader._base_options = options

        def restore():
            global _installation
            with _LOCK:
                if downloader._base_options is options:
                    downloader._base_options = original
                if _installation is restore:
                    _installation = None

        _installation = restore
        return restore
