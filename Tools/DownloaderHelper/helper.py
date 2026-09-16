"""Launch the preserved downloader as a private, parent-owned desktop service."""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import importlib
import importlib.util
import json
import os
import secrets
import signal
import socket
import sys
import threading
from pathlib import Path

from host import install_desktop_adapter

ROOT = Path(__file__).resolve().parent
VENDOR = ROOT / "vendor" / "rednote"
SHUTDOWN_GRACE_SECONDS = 45.0
MAX_COMMAND_BYTES = 65_536


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stdio", action="store_true", required=True)
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--download-dir", type=Path, required=True)
    parser.add_argument("--ffmpeg", type=Path, required=True)
    parser.add_argument("--ffprobe", type=Path, required=True)
    return parser.parse_args(argv)


def validate_paths(args):
    for name in ("data_dir", "download_dir", "ffmpeg", "ffprobe"):
        path = getattr(args, name)
        if not path.is_absolute():
            raise ValueError(f"{name} must be an absolute path")
    for name in ("ffmpeg", "ffprobe"):
        path = getattr(args, name).resolve(strict=True)
        if not path.is_file() or not os.access(path, os.X_OK):
            raise ValueError(f"{name} must be an executable file")
        setattr(args, name, path)
    if args.ffmpeg.parent != args.ffprobe.parent:
        raise ValueError("FFmpeg and FFprobe must be in the same bundled directory")
    for name in ("data_dir", "download_dir"):
        path = getattr(args, name).resolve()
        if path == Path(path.anchor) or path == Path.home():
            raise ValueError(f"{name} cannot be a home or filesystem root")
        if (
            path == ROOT
            or ROOT in path.parents
            or any(part.lower().endswith(".app") for part in path.parts)
        ):
            raise ValueError(f"{name} cannot be inside the helper bundle")
        path.mkdir(parents=True, exist_ok=True)
        if name == "data_dir":
            path.chmod(0o700)
        setattr(args, name, path)


def prepare_environment(args):
    sys.dont_write_bytecode = True
    os.environ["CHENGYING_DOWNLOAD_DATA_DIR"] = str(args.data_dir)
    os.environ["CHENGYING_DOWNLOAD_DEFAULT_DIR"] = str(args.download_dir)
    os.environ["PYTHONUTF8"] = "1"
    os.environ["PYTHONIOENCODING"] = "utf-8"
    executable_dir = str(Path(sys.executable).resolve().parent)
    # In a frozen build Deno is next to the helper. On macOS yt-dlp only searches
    # PATH, unlike its Windows executable-directory fallback.
    os.environ["PATH"] = os.pathsep.join(
        [
            str(args.ffmpeg.parent),
            executable_dir,
            os.environ.get("PATH", "/usr/bin:/bin"),
        ]
    )
    if str(VENDOR) not in sys.path:
        sys.path.insert(0, str(VENDOR))
    if "app" in sys.modules:
        raise RuntimeError("The downloader package was imported before isolation")
    specification = importlib.util.spec_from_file_location(
        "app",
        VENDOR / "app" / "__init__.py",
        submodule_search_locations=[str(VENDOR / "app")],
    )
    if specification is None or specification.loader is None:
        raise RuntimeError("The bundled downloader source is unavailable")
    package = importlib.util.module_from_spec(specification)
    sys.modules["app"] = package
    specification.loader.exec_module(package)


class ShutdownController:
    def __init__(self, *, emit, own_process_group: bool, grace=SHUTDOWN_GRACE_SECONDS):
        self.emit = emit
        self.own_process_group = own_process_group
        self.grace = grace
        self.requested = threading.Event()
        self.finished = threading.Event()

    def request(self):
        if self.requested.is_set():
            return
        self.requested.set()
        threading.Thread(
            target=self._watchdog, name="desktop-stop-watchdog", daemon=True
        ).start()

    def _watchdog(self):
        if self.finished.wait(self.grace):
            return
        # Never target a parent, a launcher group, or an unrelated Chrome session.
        if self.own_process_group and os.getpgrp() == os.getpid():
            os.killpg(os.getpid(), signal.SIGKILL)
        os._exit(2)

    def read_commands(self, stream):
        try:
            while not self.requested.is_set():
                line = stream.readline(MAX_COMMAND_BYTES + 1)
                if not line:
                    break
                if len(line) > MAX_COMMAND_BYTES:
                    break
                try:
                    request = json.loads(line)
                except (ValueError, UnicodeError):
                    break
                if not isinstance(request, dict):
                    break
                command = request.get("command")
                if command == "shutdown":
                    break
                if command == "ping":
                    self.emit({"type": "pong", "protocol_version": 1})
                else:
                    break
        finally:
            self.request()


def main(argv=None):
    if (sys.argv[1:] if argv is None else argv) == ["--self-test"]:
        from bundle_smoke import run

        return run()
    args = parse_arguments(argv)
    protocol_output = sys.stdout
    output_lock = threading.Lock()

    def emit(payload):
        with output_lock:
            try:
                protocol_output.write(json.dumps(payload, ensure_ascii=True) + "\n")
                protocol_output.flush()
            except (BrokenPipeError, OSError):
                if controller is not None:
                    controller.request()

    controller = None
    engine = None
    listener = None
    lock = None
    restore_proxy_transports = None
    sys.stdout = sys.stderr
    # Private task/config files; this does not alter files in the user's source repo.
    os.umask(0o077)
    own_process_group = False
    try:
        try:
            os.setsid()
            own_process_group = True
        except OSError:
            own_process_group = os.getpgrp() == os.getpid()
        controller = ShutdownController(emit=emit, own_process_group=own_process_group)
        # Signals and a parent-owned pipe both request bounded, state-preserving exit.
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, lambda *_: controller.request())
        threading.Thread(
            target=controller.read_commands,
            args=(sys.stdin.buffer,),
            name="desktop-parent-pipe",
            daemon=True,
        ).start()
        validate_paths(args)
        prepare_environment(args)
        from app.runtime import (
            RUNTIME_STOP_EVENT,
            ProjectLock,
            configure_runtime_identity,
        )

        lock = ProjectLock(args.data_dir / "desktop.lock")
        lock.acquire()
        engine = importlib.import_module("app.main")
        from proxy_config import ProxySettings
        from proxy_transport import install_proxy_transports

        proxy_settings = ProxySettings(args.data_dir, engine.manager)
        restore_proxy_transports = install_proxy_transports(proxy_settings.proxy_url)
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen(128)
        listener.set_inheritable(False)
        port = listener.getsockname()[1]
        token = secrets.token_urlsafe(48)
        origin = f"http://127.0.0.1:{port}"
        configure_runtime_identity(
            instance_id=secrets.token_hex(16),
            stop_token=secrets.token_urlsafe(48),
            server_port=port,
        )
        application = install_desktop_adapter(
            engine,
            token=token,
            origin=origin,
            assets=ROOT / "static",
            proxy_settings=proxy_settings,
        )
        import uvicorn

        class DesktopServer(uvicorn.Server):
            async def startup(self, sockets=None):
                await super().startup(sockets=sockets)
                if self.started and not controller.requested.is_set():
                    emit(
                        {
                            "type": "ready",
                            "protocol_version": 1,
                            "url": origin + "/",
                            "token": token,
                            "pid": os.getpid(),
                        }
                    )

            @contextlib.contextmanager
            def capture_signals(self):
                # Keep the parent-pipe watchdog active during lifespan shutdown.
                yield

        server = DesktopServer(
            uvicorn.Config(
                application,
                host="127.0.0.1",
                port=port,
                access_log=False,
                log_level="error",
                lifespan="on",
                loop="asyncio",
                http="h11",
                ws="none",
                timeout_graceful_shutdown=5,
            )
        )

        async def serve():
            async def observe_shutdown():
                while (
                    not controller.requested.is_set()
                    and not RUNTIME_STOP_EVENT.is_set()
                ):
                    await asyncio.sleep(0.1)
                controller.request()
                # Cancel work before Uvicorn drains long-lived SSE connections.
                await asyncio.to_thread(engine.manager.shutdown, False, True)
                server.should_exit = True

            watcher = asyncio.create_task(observe_shutdown())
            try:
                if not controller.requested.is_set():
                    await server.serve(sockets=[listener])
            finally:
                watcher.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await watcher

        asyncio.run(serve())
        emit({"type": "stopped", "protocol_version": 1})
        return 0
    except Exception as exc:  # noqa: BLE001 -- Keep private diagnostics out of the IPC channel.
        # Do not reflect paths, signed URLs, cookies, or arbitrary backend errors.
        code = (
            "already_running"
            if type(exc).__name__ == "ProjectLockHeldError"
            else "startup_failed"
        )
        emit(
            {
                "type": "failed",
                "code": code,
                "message": "Download center could not start.",
            }
        )
        return 1
    finally:
        if controller is not None:
            controller.request()
        if engine is not None:
            engine.manager.shutdown(wait=True, cancel_running=True)
        if restore_proxy_transports is not None:
            restore_proxy_transports()
        if listener is not None:
            listener.close()
        if lock is not None:
            lock.release()
        if controller is not None:
            controller.finished.set()


if __name__ == "__main__":
    raise SystemExit(main())
