"""Offline runtime installation and cancellable child-process supervision."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import posixpath
import queue
import re
import shutil
import signal
import subprocess
import tarfile
import tempfile
import threading
import time
from collections.abc import Callable
from contextlib import contextmanager
from pathlib import Path

from downloads import (
    Artifact,
    ArtifactStore,
    AssetError,
    Cancelled,
    check_cancelled,
    ensure_space,
    relative_path,
    safe_path,
)


@contextmanager
def operation_lock(root: Path):
    path = safe_path(root, ".subtitle-operation.lock")
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise AssetError("Another subtitle operation is using this data directory.") from exc
        yield
    finally:
        os.close(descriptor)


def stop_process(process: subprocess.Popen) -> None:
    # The process may have exited while a grandchild remains in its group.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        if process.poll() is None:
            process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        if process.poll() is None:
            process.kill()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass


def run_process(command: list[str], cancel: threading.Event, on_line: Callable[[str], None], *, env: dict | None = None, on_stderr: Callable[[str], None] | None = None, stdin_payload: str | None = None) -> int:
    check_cancelled(cancel)
    process = subprocess.Popen(
        command, stdin=subprocess.PIPE if stdin_payload is not None else subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE if on_stderr is not None else subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace",
        start_new_session=True, env=env,
    )
    lines: queue.Queue[tuple[str, str | None]] = queue.Queue()

    def read_output(stream, name: str) -> None:
        try:
            for line in stream:
                lines.put((name, line.rstrip("\r\n")))
        finally:
            lines.put((name, None))

    streams = [(process.stdout, "stdout")]
    if on_stderr is not None:
        streams.append((process.stderr, "stderr"))
    readers = [threading.Thread(target=read_output, args=(stream, name), daemon=True) for stream, name in streams]
    for reader in readers:
        reader.start()
    try:
        if stdin_payload is not None:
            # The owned source helper treats EOF as cancellation. Keep this pipe
            # open until exit, but never expose private configuration in argv.
            if len(stdin_payload.encode("utf-8")) > 65536:
                raise AssetError("The child request is too large.")
            process.stdin.write(stdin_payload + "\n")
            process.stdin.flush()
        finished = 0
        while finished < len(readers):
            check_cancelled(cancel)
            try:
                name, line = lines.get(timeout=0.1)
            except queue.Empty:
                continue
            if line is None:
                finished += 1
            elif name == "stderr":
                assert on_stderr is not None
                on_stderr(line)
            else:
                on_line(line)
        while process.poll() is None:
            check_cancelled(cancel)
            time.sleep(0.05)
        check_cancelled(cancel)
        return process.returncode
    finally:
        stop_process(process)
        if process.stdin is not None:
            process.stdin.close()
        for reader in readers:
            reader.join(timeout=1)
        for stream, _ in streams:
            if stream is not None:
                stream.close()


def extract_runtime(archive: Path, target: Path, cancel: threading.Event, on_progress: Callable[[int, int], None]) -> None:
    """Extract regular files and safe internal links; reject special devices."""
    with tarfile.open(archive, "r:*") as source:
        members = source.getmembers()
        total = sum(member.size for member in members if member.isfile())
        ensure_space(target, total)
        paths: set[str] = set()
        links: list[tarfile.TarInfo] = []
        for member in members:
            name = member.name.rstrip("/")
            # Some tar producers prepend './' to every entry.
            while name.startswith("./"):
                name = name[2:]
            if not name and member.isdir():
                member.name = ""
                continue
            relative_path(name)
            if name in paths:
                raise AssetError("The Python archive contains duplicate paths.")
            paths.add(name)
            member.name = name
            if member.issym() or member.islnk():
                link = member.linkname
                if not link or "\\" in link or "\x00" in link or link.startswith("/"):
                    raise AssetError("The Python archive contains an unsafe link.")
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), link) if member.issym() else link)
                relative_path(resolved)
                links.append(member)
            elif not member.isdir() and not member.isfile():
                raise AssetError("The Python archive contains unsupported special files.")
        completed = 0
        for member in members:
            check_cancelled(cancel)
            if not member.name or member.issym() or member.islnk():
                continue
            destination = safe_path(target, member.name, parents=True)
            if member.isdir():
                destination.mkdir(exist_ok=True)
                continue
            stream = source.extractfile(member)
            if stream is None:
                raise AssetError("Unable to read a Python archive entry.")
            with stream, destination.open("xb") as output:
                while chunk := stream.read(1024**2):
                    check_cancelled(cancel)
                    output.write(chunk)
                    completed += len(chunk)
                    on_progress(completed, total)
            destination.chmod(member.mode & 0o777)
        # Delay links until regular extraction has finished, preventing writes through links.
        for member in links:
            check_cancelled(cancel)
            destination = safe_path(target, member.name, parents=True)
            if member.issym():
                destination.symlink_to(member.linkname)
            else:
                link_target = safe_path(target, posixpath.normpath(member.linkname))
                if not link_target.is_file():
                    raise AssetError("A Python archive hard link has no regular target.")
                os.link(link_target, destination, follow_symlinks=False)
        for member in links:
            destination = target / member.name
            try:
                destination.resolve(strict=True).relative_to(target)
            except (OSError, RuntimeError, ValueError) as exc:
                raise AssetError("A Python archive link resolves outside the runtime.") from exc


class Runtime:
    def __init__(self, root: Path, manifest: dict, fingerprint: str) -> None:
        self.root = root
        self.spec = manifest["runtime"]
        self.fingerprint = hashlib.sha256(json.dumps(self.spec, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        migrations = manifest.get("legacy_runtime_manifests", {})
        if not isinstance(migrations, dict):
            raise AssetError("Invalid runtime migration manifest.")
        self.legacy_fingerprints = {fingerprint, *(old for old, current in migrations.items() if current == self.fingerprint)}
        identifier = self.spec.get("id", "")
        if not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", identifier):
            raise AssetError("Invalid runtime identifier.")
        relative_path(self.spec.get("python_executable", ""))
        self.directory = safe_path(root, f"runtime/{identifier}")
        requirements = self.spec.get("requirements")
        if not isinstance(requirements, list) or not requirements:
            raise AssetError("The runtime requires a complete hashed wheel lock.")
        for requirement in requirements:
            if not isinstance(requirement, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+==[A-Za-z0-9.+!_-]+(?: --hash=sha256:[0-9a-f]{64})+", requirement):
                raise AssetError("Runtime requirements must be exact versions with SHA-256 hashes.")

    def python(self, directory: Path | None = None) -> Path:
        base = directory or self.directory
        path = base / self.spec["python_executable"]
        try:
            resolved = path.resolve(strict=True)
            resolved.relative_to(base)
            if not resolved.is_file():
                raise ValueError("Not a file")
        except (OSError, ValueError, RuntimeError) as exc:
            raise AssetError("The isolated Python runtime is missing or invalid.") from exc
        return path

    def ready(self) -> bool:
        try:
            marker = safe_path(self.root, f"runtime/{self.spec['id']}/.ready.json")
            payload = json.loads(marker.read_text(encoding="utf-8"))
            executable = self.python()
            return payload.get("validation_version") == 1 and payload.get("manifest_sha256") == self.fingerprint and payload.get("python_sha256") == hashlib.sha256(executable.read_bytes()).hexdigest()
        except Cancelled:
            raise
        except (OSError, ValueError, AssetError):
            return False

    def ensure(self, cancel: threading.Event, progress: Callable[[dict], None]) -> None:
        if self.ready():
            return
        if self._migrate_marker(cancel, progress):
            return
        parent = safe_path(self.root, "runtime/.parent-check", parents=True).parent
        staging = Path(tempfile.mkdtemp(prefix=".installing-", dir=parent))
        try:
            archive = safe_path(self.root, self.spec["archive"]["path"])
            progress({"stage": "runtime_extract", "message": "Extracting the verified Python runtime."})
            extract_runtime(archive, staging, cancel, lambda done, total: progress({"stage": "runtime_extract", "progress": done / max(1, total), "message": "Extracting the verified Python runtime."}))
            python = self.python(staging)
            wheel_bytes = sum(item["size"] for item in self.spec["wheels"])
            ensure_space(parent, wheel_bytes * 3)
            lock_path = staging / "requirements.lock"
            lock_path.write_text("\n".join(self.spec["requirements"]) + "\n", encoding="utf-8")
            environment = dict(os.environ, PYTHONNOUSERSITE="1", PIP_NO_INDEX="1", PIP_DISABLE_PIP_VERSION_CHECK="1", PYTHONUTF8="1", HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
            for key in ("PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV"):
                environment.pop(key, None)
            log_tail: list[str] = []

            def log(line: str) -> None:
                log_tail.append(line)
                del log_tail[:-8]

            progress({"stage": "runtime_install", "message": "Installing verified wheels offline; no model download is running."})
            boot = [str(python), "-I", "-m", "ensurepip", "--upgrade"]
            if run_process(boot, cancel, log, env=environment) != 0:
                raise AssetError("Unable to initialize offline pip: " + "\n".join(log_tail))
            command = [str(python), "-I", "-m", "pip", "--isolated", "--disable-pip-version-check", "--no-input", "install", "--no-index", "--no-deps", "--require-hashes", "--only-binary=:all:"]
            for directory in sorted({str(safe_path(self.root, item["path"]).parent) for item in self.spec["wheels"]}):
                command.extend(["--find-links", directory])
            command.extend(["-r", str(lock_path)])
            if run_process(command, cancel, log, env=environment) != 0:
                raise AssetError("Offline runtime installation failed: " + "\n".join(log_tail))
            progress({"stage": "runtime_validate", "message": "Checking local AI runtime imports; model weights are not being loaded."})
            log_tail.clear()
            validation = (
                "import torch, accelerate, soundfile, nagisa, soynlp, safetensors; "
                "from opencc import OpenCC; "
                "from transformers import AutoProcessor, AutoTokenizer, AutoModelForMultimodalLM, AutoModelForTokenClassification, AutoModelForCausalLM; "
                "assert OpenCC('t2s').convert('簡體') == '简体'; "
                "assert soundfile.available_formats(); "
                "assert torch.ones(1, dtype=torch.bfloat16).numel() == 1; "
                "print('Offline subtitle runtime imports validated.')"
            )
            if run_process([str(python), "-I", "-c", validation], cancel, log, env=environment) != 0:
                raise AssetError("Offline runtime validation failed: " + "\n".join(log_tail))
            check_cancelled(cancel)
            marker = {"validation_version": 1, "manifest_sha256": self.fingerprint, "python_sha256": hashlib.sha256(python.read_bytes()).hexdigest()}
            (staging / ".ready.json").write_text(json.dumps(marker), encoding="utf-8")
            if self.directory.exists():
                backup = safe_path(self.root, f"runtime/{self.spec['id']}.invalid-{time.time_ns()}")
                os.replace(self.directory, backup)
            os.replace(staging, self.directory)
        finally:
            if staging.exists():
                shutil.rmtree(staging)

    def _migrate_marker(self, cancel: threading.Event, progress: Callable[[dict], None]) -> bool:
        """Retain an existing validated runtime only after verifying its lock inputs."""
        try:
            marker = safe_path(self.root, f"runtime/{self.spec['id']}/.ready.json")
            payload = json.loads(marker.read_text(encoding="utf-8"))
            if (payload.get("validation_version") != 1
                    or payload.get("manifest_sha256") not in self.legacy_fingerprints
                    or payload.get("python_sha256") != hashlib.sha256(self.python().read_bytes()).hexdigest()):
                return False
            progress({"stage": "runtime_validate", "message": "Verifying the existing runtime before updating its model-independent lock."})
            store = ArtifactStore(self.root)
            for specification in [self.spec["archive"], *self.spec["wheels"]]:
                if not store.verify(Artifact.from_dict(specification), cancel, lambda *_: None):
                    return False
            check_cancelled(cancel)
            payload["manifest_sha256"] = self.fingerprint
            descriptor, temporary = tempfile.mkstemp(prefix=".ready-", dir=marker.parent)
            try:
                with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                    json.dump(payload, stream)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, marker)
            finally:
                Path(temporary).unlink(missing_ok=True)
            return True
        except Cancelled:
            raise
        except (OSError, ValueError, AssetError):
            return False
