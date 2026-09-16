"""Verified, resumable downloads using only the Python standard library."""

from __future__ import annotations

import hashlib
import http.client
import os
import re
import shutil
import ssl
import stat
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


class AssetError(RuntimeError):
    pass


class Cancelled(AssetError):
    pass


def check_cancelled(cancel: threading.Event) -> None:
    if cancel.is_set():
        raise Cancelled("Operation cancelled.")


def relative_path(value: str) -> Path:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        raise AssetError("Invalid asset path.")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in ("", ".", "..") for part in value.split("/")):
        raise AssetError("Asset paths must be relative and cannot contain traversal.")
    return Path(*path.parts)


def safe_path(root: Path, relative: str, *, parents: bool = False) -> Path:
    """Reject symlink components before touching a managed asset."""
    result = root / relative_path(relative)
    # Ancestors are checked explicitly, including the data root.
    current = Path(root.anchor)
    for part in root.parts[1:]:
        current /= part
        if current.is_symlink():
            raise AssetError("The data directory cannot contain symbolic links.")
    current = root
    for part in result.relative_to(root).parts:
        current /= part
        if current.is_symlink():
            raise AssetError("Managed asset paths cannot contain symbolic links.")
    if parents:
        result.parent.mkdir(parents=True, exist_ok=True)
        return safe_path(root, relative)
    return result


def ensure_space(path: Path, required: int, reserve: int = 256 * 1024**2) -> None:
    existing = path
    while not existing.exists():
        existing = existing.parent
    if shutil.disk_usage(existing).free < max(0, required) + reserve:
        raise AssetError("Not enough free disk space for the remaining download or installation.")


@dataclass(frozen=True)
class Artifact:
    id: str
    path: str
    url: str
    size: int
    sha256: str

    @classmethod
    def from_dict(cls, value: dict) -> Artifact:
        try:
            artifact = cls(**{key: value[key] for key in ("id", "path", "url", "size", "sha256")})
        except (KeyError, TypeError) as exc:
            raise AssetError("Invalid artifact manifest entry.") from exc
        relative_path(artifact.path)
        if not isinstance(artifact.id, str) or not artifact.id:
            raise AssetError("Missing artifact identifier.")
        if type(artifact.size) is not int or artifact.size <= 0:
            raise AssetError("Invalid artifact size.")
        if not isinstance(artifact.sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", artifact.sha256):
            raise AssetError("Every artifact needs a fixed SHA-256 digest.")
        if not isinstance(artifact.url, str):
            raise AssetError("Invalid artifact URL.")
        return artifact


Progress = Callable[[Artifact, str, int, float | None], None]


def certificate_file() -> str | None:
    configured = os.environ.get("SSL_CERT_FILE")
    if configured:
        return configured
    bundled = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent)) / "cacert.pem"
    if bundled.is_file():
        return str(bundled)
    system = Path("/etc/ssl/cert.pem")
    if sys.platform == "darwin" and system.is_file():
        return str(system)
    return None


class _SafeRedirect(urllib.request.HTTPRedirectHandler):
    def __init__(self, validate: Callable[[str], None]) -> None:
        self.validate = validate

    def redirect_request(self, request, fp, code, message, headers, newurl):
        self.validate(newurl)
        return super().redirect_request(request, fp, code, message, headers, newurl)


class ArtifactStore:
    def __init__(self, root: Path, *, allow_local_http: bool = False, reserve_bytes: int = 256 * 1024**2) -> None:
        self.root = Path(os.path.abspath(root))
        safe_path(self.root, "path-check")
        self.root.mkdir(parents=True, exist_ok=True)
        self.allow_local_http = allow_local_http
        self.reserve_bytes = reserve_bytes
        self._verified: dict[str, tuple] = {}
        self._lock = threading.RLock()
        context = ssl.create_default_context(cafile=certificate_file())
        self._opener = urllib.request.build_opener(_SafeRedirect(self._validate_url), urllib.request.HTTPSHandler(context=context))

    def _validate_url(self, url: str) -> None:
        parsed = urllib.parse.urlsplit(url)
        local = self.allow_local_http and parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost", "::1"}
        if (parsed.scheme != "https" and not local) or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
            raise AssetError("Model and runtime downloads require HTTPS without URL credentials.")

    def path(self, artifact: Artifact, *, partial: bool = False) -> Path:
        return safe_path(self.root, artifact.path + (".part" if partial else ""))

    @staticmethod
    def _signature(path: Path) -> tuple:
        info = path.stat(follow_symlinks=False)
        if not stat.S_ISREG(info.st_mode):
            raise AssetError("An asset path is not a regular file.")
        return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)

    def ready(self, artifact: Artifact) -> bool:
        with self._lock:
            try:
                return self._verified.get(artifact.path) == (artifact.sha256, self._signature(self.path(artifact)))
            except FileNotFoundError:
                return False

    def downloaded(self, artifact: Artifact) -> int:
        for partial in (False, True):
            path = self.path(artifact, partial=partial)
            try:
                return min(artifact.size, self._signature(path)[2])
            except FileNotFoundError:
                pass
        return 0

    def verify(self, artifact: Artifact, cancel: threading.Event, progress: Progress | None = None, *, partial: bool = False) -> bool:
        path = self.path(artifact, partial=partial)
        check_cancelled(cancel)
        if not partial and self.ready(artifact):
            return True
        try:
            signature = self._signature(path)
        except FileNotFoundError:
            return False
        if signature[2] != artifact.size:
            return False
        digest = hashlib.sha256()
        started = time.monotonic()
        count = 0
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as source:
            while chunk := source.read(4 * 1024**2):
                check_cancelled(cancel)
                digest.update(chunk)
                count += len(chunk)
                if progress:
                    progress(artifact, "verify", count, count / max(0.001, time.monotonic() - started))
        check_cancelled(cancel)
        if self._signature(path) != signature:
            raise AssetError("An asset changed during verification.")
        valid = digest.hexdigest() == artifact.sha256
        if valid and not partial:
            with self._lock:
                self._verified[artifact.path] = (artifact.sha256, signature)
        return valid

    def ensure(self, artifact: Artifact, cancel: threading.Event, progress: Progress | None = None) -> Path:
        self._validate_url(artifact.url)
        check_cancelled(cancel)
        destination = safe_path(self.root, artifact.path, parents=True)
        partial = self.path(artifact, partial=True)
        if self.verify(artifact, cancel, progress):
            return destination
        if destination.exists():
            # A previously published file was modified or came from another manifest.
            # Never load it; keep it recoverable, but do not use it as a resume prefix.
            invalid = safe_path(self.root, artifact.path + ".invalid")
            os.replace(destination, invalid)
        if partial.exists() and self._signature(partial)[2] > artifact.size:
            partial.unlink()
        started = time.monotonic()
        received = 0
        while True:
            check_cancelled(cancel)
            offset = self._signature(partial)[2] if partial.exists() else 0
            if offset == artifact.size:
                if not self.verify(artifact, cancel, progress, partial=True):
                    partial.unlink()
                    raise AssetError(f"SHA-256 verification failed for {artifact.id}; retry to download a clean copy.")
                check_cancelled(cancel)
                safe_path(self.root, artifact.path)
                os.replace(partial, destination)
                with self._lock:
                    self._verified[artifact.path] = (artifact.sha256, self._signature(destination))
                return destination
            ensure_space(self.root, artifact.size - offset, self.reserve_bytes)
            request = urllib.request.Request(artifact.url, headers={"User-Agent": "ChengYing-SubtitleTools/1", "Accept-Encoding": "identity"})
            if offset:
                request.add_header("Range", f"bytes={offset}-")
            try:
                response = self._opener.open(request, timeout=15)
            except urllib.error.HTTPError as exc:
                if exc.code == 416 and partial.exists() and self._signature(partial)[2] == artifact.size:
                    continue
                raise AssetError(f"Download failed for {artifact.id}: HTTP {exc.code}; partial data was retained.") from exc
            except (OSError, urllib.error.URLError) as exc:
                check_cancelled(cancel)
                raise AssetError(f"Download interrupted for {artifact.id}; partial data was retained: {exc}") from exc
            with response:
                self._validate_url(response.geturl())
                if response.headers.get("Content-Encoding", "identity").lower() not in {"", "identity"}:
                    raise AssetError("Compressed download responses cannot be resumed safely.")
                status = response.status
                if status == 206:
                    match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", response.headers.get("Content-Range", ""))
                    if not match:
                        raise AssetError("Invalid Content-Range response; partial data was retained.")
                    begin, end, total = map(int, match.groups())
                    if begin != offset or total != artifact.size or not begin <= end < total:
                        raise AssetError("The resumed download range does not match the fixed artifact.")
                    expected = end - begin + 1
                    mode = os.O_APPEND
                elif status == 200:
                    offset = 0
                    expected = artifact.size
                    mode = os.O_TRUNC
                else:
                    raise AssetError(f"Unexpected download response: HTTP {status}.")
                content_length = response.headers.get("Content-Length")
                if content_length is not None and (not content_length.isdigit() or int(content_length) != expected):
                    raise AssetError("The download length does not match the fixed artifact.")
                descriptor = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | mode, 0o600)
                read_count = 0
                try:
                    with os.fdopen(descriptor, "wb") as output:
                        while True:
                            check_cancelled(cancel)
                            # read1 preserves received bytes even if the next network read fails.
                            chunk = response.read1(min(1024**2, expected - read_count + 1))
                            if not chunk:
                                break
                            if read_count + len(chunk) > expected:
                                raise AssetError("The server sent more data than the declared artifact size.")
                            output.write(chunk)
                            output.flush()
                            read_count += len(chunk)
                            received += len(chunk)
                            if progress:
                                progress(artifact, "download", offset + read_count, received / max(0.001, time.monotonic() - started))
                        os.fsync(output.fileno())
                except (OSError, urllib.error.URLError, http.client.HTTPException) as exc:
                    check_cancelled(cancel)
                    raise AssetError(f"Download interrupted for {artifact.id}; partial data was retained: {exc}") from exc
                if read_count != expected:
                    raise AssetError(f"Download ended early for {artifact.id}; partial data was retained.")
