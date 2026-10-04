"""Verify shipped filename handling with synthetic names and private directories."""

from __future__ import annotations

import tempfile
import unicodedata
from pathlib import Path


def verify_filename_runtime() -> str:
    from app.downloader import safe_component

    try:
        samples = [
            "Synthetic\ufff4Author", "Synthetic\uffffTitle", "Synthetic\ud800Name",
            "a" + "\u0301" * 60, "\ufff4" * 8, "Example Author",
            "\u4f5c\u8005", "\U0001f469\u200d\U0001f4bb", "\ue000Private",
        ]
        with tempfile.TemporaryDirectory(prefix="chengying-filename-smoke-") as temporary:
            root = Path(temporary)
            for index, sample in enumerate(samples):
                component = safe_component(sample)
                if not component or len(component.encode("utf-8")) > 120:
                    raise RuntimeError("Invalid synthetic filename length")
                if any(unicodedata.category(c) in {"Cn", "Cs"} for c in component):
                    raise RuntimeError("Unsafe synthetic filename code point")
                container = root / str(index)
                container.mkdir()
                destination = container / component
                destination.mkdir()
                (destination / (safe_component(sample) + ".txt")).touch()
    except Exception:  # noqa: BLE001 - Never expose local paths in build reports.
        raise RuntimeError("The bundled filename offline verification failed") from None
    return "unicode-author-and-media-names-verified-offline"
