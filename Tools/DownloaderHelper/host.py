"""Authenticated desktop adapter around the preserved downloader application."""

from __future__ import annotations

import secrets
import stat
from http.cookies import CookieError, SimpleCookie
from pathlib import Path
from urllib.parse import urlsplit
from uuid import UUID

from fastapi import HTTPException, Query, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from proxy_config import ProxySettingsError
from pydantic import ValidationError
from starlette.concurrency import run_in_threadpool
from update_maintenance import UpdateMaintenance, UpdateMaintenanceMiddleware

COOKIE_NAME = "chengying_download_session"
VIDEO_EXTENSIONS = frozenset(
    {
        ".mp4",
        ".m4v",
        ".mov",
        ".mkv",
        ".webm",
        ".avi",
        ".ts",
        ".m2ts",
        ".flv",
        ".mts",
        ".3gp",
        ".mpeg",
        ".mpg",
        ".ogv",
    }
)
IMAGE_EXTENSIONS = frozenset(
    {".jpg", ".jpeg", ".png", ".webp", ".avif", ".gif", ".heic", ".heif"}
)


class DesktopSessionMiddleware:
    """Keep every HTTP endpoint private to this launch, including SSE/assets."""

    def __init__(self, app, *, token: str, origin: str):
        self.app = app
        self.token = token
        self.origin = origin
        self.authority = urlsplit(origin).netloc

    async def __call__(self, scope, receive, send):
        if scope["type"] == "websocket":
            await send({"type": "websocket.close", "code": 1008})
            return
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        headers = {}
        duplicate = False
        for name, value in scope.get("headers", []):
            key = name.decode("latin-1").lower()
            if key in headers and key in {"host", "cookie", "origin", "referer"}:
                duplicate = True
            headers[key] = value.decode("latin-1")
        client = scope.get("client")
        allowed = (
            not duplicate
            and client is not None
            and client[0] in {"127.0.0.1", "::1", "testclient"}
            and headers.get("host") == self.authority
            and headers.get("origin", self.origin) == self.origin
            and headers.get("sec-fetch-site", "same-origin") in {"same-origin", "none"}
        )
        if "referer" in headers:
            try:
                parsed = urlsplit(headers["referer"])
                allowed = (
                    allowed and f"{parsed.scheme}://{parsed.netloc}" == self.origin
                )
            except ValueError:
                allowed = False
        cookie = SimpleCookie()
        try:
            cookie.load(headers.get("cookie", ""))
            supplied = cookie.get(COOKIE_NAME)
            valid_token = bool(
                supplied
                and secrets.compare_digest(supplied.value.encode(), self.token.encode())
            )
        except (CookieError, UnicodeError):
            valid_token = False
        if not allowed or not valid_token:
            await JSONResponse({"detail": "Desktop session required"}, status_code=403)(
                scope, receive, send
            )
            return

        async def protected_send(message):
            if message["type"] == "http.response.start":
                message = dict(message)
                message["headers"] = [
                    *message.get("headers", []),
                    (b"cache-control", b"no-store"),
                    (b"x-content-type-options", b"nosniff"),
                    (b"referrer-policy", b"no-referrer"),
                    (
                        b"content-security-policy",
                        (
                            b"default-src 'self'; script-src 'self'; "
                            b"style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
                            b"connect-src 'self'; object-src 'none'; frame-src 'none'; "
                            b"frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
                        ),
                    ),
                ]
            await send(message)

        await self.app(scope, receive, protected_send)


def resolve_output(manager, job_id: str, item_id: str, index: int) -> dict[str, str]:
    """Only expose a completed, recorded regular media file inside its job root."""
    try:
        job = manager.get_job(job_id)
        item = next(item for item in job.items if item.id == item_id)
        if item.status != "completed" or index < 0:
            raise ValueError("Output is not complete")
        raw_path = Path(item.output_paths[index])
        if not raw_path.is_absolute():
            raise ValueError("Output is not absolute")
        root = Path(job.output_root).resolve(strict=True)
        path = raw_path.resolve(strict=True)
        path.relative_to(root)
        if not stat.S_ISREG(path.stat().st_mode):
            raise ValueError("Output is not a regular file")
        extension = path.suffix.lower()
        if extension in VIDEO_EXTENSIONS:
            media_type = "video"
        elif extension in IMAGE_EXTENSIONS:
            media_type = "image"
        else:
            raise ValueError("Output is not a supported media file")
        return {"path": str(path), "media_type": media_type}
    except (KeyError, StopIteration, IndexError, ValueError, OSError, RuntimeError):
        raise HTTPException(
            status_code=404,
            detail="The completed media file is no longer available in its download folder.",
        ) from None


def validate_download_directory(value: object, *, bundle_root: Path) -> str:
    if not isinstance(value, str) or not value.strip() or "\0" in value:
        raise HTTPException(
            status_code=422, detail="Choose an absolute download folder path."
        )
    try:
        path = Path(value.strip()).expanduser()
        if not path.is_absolute():
            raise HTTPException(
                status_code=422, detail="Use Choose Folder or enter an absolute path."
            )
        path = path.resolve()
    except (OSError, RuntimeError, ValueError):
        raise HTTPException(
            status_code=422, detail="The download folder path is invalid."
        ) from None
    if (
        path in {Path(path.anchor), Path.home().resolve(), bundle_root}
        or bundle_root in path.parents
        or any(part.lower().endswith(".app") for part in path.parts)
    ):
        raise HTTPException(
            status_code=422, detail="Choose a media folder outside application bundles."
        )
    return str(path)


def install_desktop_adapter(
    engine, *, token: str, origin: str, assets: Path, proxy_settings=None,
    login_sessions=None, login_policy=None,
):
    application = engine.app
    maintenance = UpdateMaintenance(
        engine.manager, additional_activity=login_sessions.active if login_sessions else None
    )
    from chrome_profiles import (
        PROFILE_DIRECTORY_RE,
        list_chrome_profiles,
        validate_chrome_profile,
    )

    def require_profile(config):
        if not config.use_chrome_cookies:
            return
        code = validate_chrome_profile(config.chrome_profile)
        if code is not None:
            raise HTTPException(status_code=422, detail={
                "code": code,
                "message": "Select an available Chrome profile in download settings and save before creating a new task.",
            })

    def login_mode():
        return login_policy.mode() if login_policy is not None else "chrome"

    def login_error_detail(code):
        messages = {
            "login_session_missing": "请先在“下载登录”中打开对应平台的专用窗口，手动登录并保存，再创建下载任务。",
            "login_session_expired": "专用登录已过期。请重新登录并保存，再从原链接创建新任务；无需授权日常 Chrome。",
            "login_session_invalid": "专用登录记录无法安全读取，请在下载登录面板重新登录并保存。",
            "login_busy": "专用登录窗口仍在处理，请完成并保存登录，或关闭该窗口后再创建任务。",
        }
        return {"code": code, "message": messages.get(code,
            "专用下载登录暂不可用，请在下载登录面板刷新状态并检查提示；不要发送 Cookie 或密码。")}
    # The original engine/API/static files remain unmodified. Only its host page
    # receives desktop affordances; its own build handshake still covers its source.
    application.router.routes[:] = [
        route
        for route in application.router.routes
        if getattr(route, "path", None)
        not in {"/", "/api/docs", "/docs/oauth2-redirect", "/openapi.json"}
        and not (
            getattr(route, "path", None) == "/api/config"
            and "PUT" in getattr(route, "methods", set())
        )
        and not (
            getattr(route, "path", None) == "/api/jobs"
            and "POST" in getattr(route, "methods", set())
        )
    ]

    @application.put("/api/config", include_in_schema=False)
    async def desktop_config(request: Request):
        raw = bytearray()
        async for part in request.stream():
            raw.extend(part)
            if len(raw) > 16_384:
                raise HTTPException(
                    status_code=413, detail="Download settings are too large."
                )
        try:
            import json

            payload = json.loads(raw)
            if not isinstance(payload, dict):
                raise TypeError("Expected a settings object")
            payload["download_dir"] = validate_download_directory(
                payload.get("download_dir"),
                bundle_root=Path(__file__).resolve().parent,
            )
            config = engine.AppConfig.model_validate(payload)
        except (TypeError, ValueError, UnicodeError, ValidationError):
            raise HTTPException(
                status_code=422, detail="Invalid download settings."
            ) from None
        def save():
            # Preserve legacy saved settings when editing unrelated fields;
            # new tasks still require an available explicit profile.
            with engine._CONFIG_LOCK:
                previous = engine.get_config()
                if login_mode() == "chrome" and (config.chrome_profile != previous.chrome_profile
                        or config.use_chrome_cookies != previous.use_chrome_cookies):
                    require_profile(config)
                return engine.update_config(config)

        return await run_in_threadpool(save)

    @application.post("/api/jobs", status_code=201, include_in_schema=False)
    async def desktop_create_job(request: Request):
        raw = bytearray()
        async for part in request.stream():
            raw.extend(part)
            if len(raw) > 16_384:
                raise HTTPException(status_code=413, detail="Download request is too large.")
        try:
            import json

            payload = json.loads(raw)
            job_request = engine.CreateJobRequest.model_validate(payload)
        except (TypeError, ValueError, UnicodeError, ValidationError):
            raise HTTPException(status_code=422, detail="Invalid download request.") from None

        def submit():
            # The validation and original submission must share one settings
            # snapshot; a concurrent save cannot change the chosen identity.
            with engine._CONFIG_LOCK:
                mode = login_mode()
                if mode == "chrome":
                    require_profile(engine.get_config())
                    return engine.create_job(job_request)
                from login_sessions import LoginSessionError
                try:
                    source = engine.identify_url(job_request.url)
                    profile = None
                    if mode == "dedicated":
                        if login_sessions.active():
                            raise HTTPException(409, detail=login_error_detail("login_busy"))
                        profile = login_sessions.current_token(source.platform.value)
                        # Recheck the actual snapshot, not a remembered UI badge.
                        login_sessions.cookie_jar(profile)
                    snapshot = engine.get_config()
                    return engine._public_job(engine.manager.create_job(
                        job_request.url, output_root=snapshot.download_dir,
                        cookie_browser="chrome" if profile else None,
                        cookie_profile=profile,
                    ))
                except LoginSessionError as error:
                    raise HTTPException(error.status, detail=login_error_detail(error.code)) from None
                except HTTPException:
                    raise
                except Exception as error:  # noqa: BLE001 -- Reuse the engine's sanitized public error mapper.
                    raise engine._http_error(error) from None

        return await run_in_threadpool(submit)

    @application.get("/", include_in_schema=False)
    def desktop_index():
        document = engine.index().body.decode("utf-8")
        login_assets = (
            '<link rel="stylesheet" href="/native/login_sessions.css">'
            '<script src="/native/login_sessions.js" defer></script>'
            if login_sessions is not None else ""
        )
        chrome_assets = (
            '<link rel="stylesheet" href="/native/chrome_profiles.css">'
            '<script src="/native/chrome_profiles.js" defer></script>'
            if login_mode() == "chrome" else ""
        )
        document = document.replace(
            "<title>原迹下载器</title>", "<title>澄影 · 下载中心</title>"
        )
        document = document.replace(
            "</head>",
            '<link rel="stylesheet" href="/native/desktop.css">'
            '<script src="/native/desktop.js" defer></script>'
            + login_assets + chrome_assets +
            '<link rel="stylesheet" href="/native/diagnostics.css">'
            '<script src="/native/diagnostics.js" defer></script></head>',
            1,
        )
        return HTMLResponse(document)

    @application.get("/api/native/output", include_in_schema=False)
    def native_output(
        job_id: str = Query(min_length=1, max_length=256),
        item_id: str = Query(min_length=1, max_length=512),
        index: int = Query(ge=0, le=100_000),
    ):
        return resolve_output(engine.manager, job_id, item_id, index)

    @application.get("/api/native/status", include_in_schema=False)
    def native_status():
        chrome_paths = (
            Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            Path.home() / "Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        )
        return {"chrome_installed": any(path.is_file() for path in chrome_paths)}

    @application.get("/api/native/chrome-profiles", include_in_schema=False)
    def native_chrome_profiles():
        if login_mode() != "chrome":
            return {"schema_version": 1, "status": "disabled", "profiles": [],
                    "selected_profile": None, "selected_status": "unverified",
                    "use_chrome_cookies": False}
        config = engine.get_config()
        result = list_chrome_profiles()
        selected = config.chrome_profile
        if selected is None:
            selected_status = "automatic"
        elif not isinstance(selected, str) or not PROFILE_DIRECTORY_RE.fullmatch(selected):
            selected_status = "invalid"
        elif result["status"] != "ok":
            selected_status = "unverified"
        else:
            selected_status = "missing"
            for profile in result["profiles"]:
                if profile["directory"] == selected:
                    selected_status = "available" if profile["has_cookie_database"] else "cookie_database_missing"
                    break
        return {**result, "schema_version": 1,
                "selected_profile": selected if selected_status not in {"automatic", "invalid"} else None,
                "selected_status": selected_status,
                "use_chrome_cookies": config.use_chrome_cookies}

    if login_sessions is not None:
        from login_auth import LoginPolicyError, is_session_profile
        from login_sessions import LoginSessionError

        @application.exception_handler(LoginPolicyError)
        async def login_policy_error(request, error):
            return JSONResponse({"detail": {"code": error.code}}, status_code=error.status)

        def login_status():
            return {**login_sessions.status(), "mode": login_mode()}

        async def login_payload(request):
            import json

            raw = bytearray()
            async for part in request.stream():
                raw.extend(part)
                if len(raw) > 1024:
                    raise HTTPException(413, detail={"code": "login_request_invalid"})
            try:
                payload = json.loads(raw)
                if not isinstance(payload, dict):
                    raise TypeError
                return payload
            except (ValueError, TypeError, UnicodeError):
                raise HTTPException(422, detail={"code": "login_request_invalid"}) from None

        @application.get("/api/native/login", include_in_schema=False)
        def get_login_status():
            return login_status()

        @application.put("/api/native/login/mode", include_in_schema=False)
        async def set_login_mode(request: Request):
            payload = await login_payload(request)
            if set(payload) != {"mode"}:
                raise HTTPException(422, detail={"code": "login_request_invalid"})

            def save_mode():
                with engine._CONFIG_LOCK, maintenance.lock:
                    if login_sessions.active():
                        raise HTTPException(409, detail={"code": "login_busy"})
                    login_policy.save(payload["mode"])
                    return login_status()

            return await run_in_threadpool(save_mode)

        @application.post("/api/native/login/{platform}/{action}", include_in_schema=False)
        async def change_login(platform: str, action: str, request: Request):
            payload = await login_payload(request)
            if payload or action not in {"open", "save"}:
                raise HTTPException(422, detail={"code": "login_request_invalid"})

            def change():
                with engine._CONFIG_LOCK, maintenance.lock:
                    if login_mode() != "dedicated":
                        raise HTTPException(409, detail={"code": "login_mode_required"})
                    try:
                        if action == "open":
                            login_sessions.start(platform)
                        else:
                            login_sessions.finish(platform)
                    except LoginSessionError as error:
                        raise HTTPException(error.status, detail={"code": error.code}) from None
                    return login_status()

            return await run_in_threadpool(change)

        # A saved task keeps its immutable login revision. Opening a fresh login
        # must not silently replace that identity during a retry.
        application.router.routes[:] = [route for route in application.router.routes
            if not (getattr(route, "path", None) == "/api/jobs/{job_id}/verify"
                    and "POST" in getattr(route, "methods", set()))]

        @application.post("/api/jobs/{job_id}/verify", include_in_schema=False)
        def verify_job_login(job_id: str):
            try:
                job = engine.manager.get_job(job_id)
                if is_session_profile(job.cookie_profile):
                    raise HTTPException(409, detail={"code": "login_refresh_new_task",
                        "message": "请在下载登录面板重新登录并保存，再从原链接新建任务；旧任务不会自动更换登录身份。"})
                return engine.open_verification(job_id)
            except HTTPException:
                raise
            except Exception as error:  # noqa: BLE001 -- Reuse the engine's sanitized public error mapper.
                raise engine._http_error(error) from None

    @application.get("/api/native/activity", include_in_schema=False)
    def native_activity():
        return maintenance.activity()

    @application.get("/api/native/diagnostics", include_in_schema=False)
    def native_diagnostics(job_id: str | None = None):
        from diagnostic_identity import runtime_identity
        from diagnostic_log import diagnostic_report

        # FastAPI's default validation body echoes invalid inputs. Keep even
        # malformed diagnostic selectors out of error responses.
        if job_id is not None and not 0 < len(job_id) <= 256:
            raise HTTPException(status_code=422, detail="Invalid diagnostic task selection.")
        try:
            return diagnostic_report(engine.manager, job_id=job_id, identity=runtime_identity())
        except KeyError:
            raise HTTPException(status_code=404, detail="The selected diagnostic task is unavailable.") from None
        except Exception:  # noqa: BLE001 -- Never expose raw report-generation errors.
            raise HTTPException(status_code=503, detail="Diagnostic report is unavailable.") from None

    @application.put("/api/native/maintenance/{identifier}", include_in_schema=False)
    def acquire_maintenance(identifier: UUID):
        return maintenance.acquire(str(identifier))

    @application.delete("/api/native/maintenance/{identifier}", include_in_schema=False)
    def release_maintenance(identifier: UUID):
        return maintenance.release(str(identifier))

    @application.put("/api/native/maintenance/{identifier}/commit", include_in_schema=False)
    def commit_maintenance(identifier: UUID):
        return maintenance.commit(str(identifier))

    def require_proxy_settings():
        if proxy_settings is None:
            raise HTTPException(
                status_code=503,
                detail={
                    "code": "proxy_unavailable",
                    "message": "Proxy settings are unavailable.",
                },
            )
        return proxy_settings

    def proxy_http_error(error):
        return HTTPException(
            status_code=error.status, detail={"code": error.code, "message": str(error)}
        )

    async def proxy_payload(request):
        raw = bytearray()
        async for part in request.stream():
            raw.extend(part)
            if len(raw) > 4096:
                raise HTTPException(
                    status_code=413,
                    detail={
                        "code": "invalid_proxy",
                        "message": "Proxy settings are too large.",
                    },
                )
        try:
            import json

            return json.loads(raw)
        except (ValueError, UnicodeError):
            raise HTTPException(
                status_code=422,
                detail={"code": "invalid_proxy", "message": "Invalid proxy settings."},
            ) from None

    @application.get("/api/native/proxy", include_in_schema=False)
    def proxy_status():
        try:
            return require_proxy_settings().status()
        except ProxySettingsError as error:
            raise proxy_http_error(error) from None

    @application.put("/api/native/proxy", include_in_schema=False)
    async def save_proxy(request: Request):
        payload = await proxy_payload(request)
        try:
            return await run_in_threadpool(require_proxy_settings().save, payload)
        except ProxySettingsError as error:
            raise proxy_http_error(error) from None

    @application.post("/api/native/proxy/test", include_in_schema=False)
    async def test_proxy(request: Request):
        settings = require_proxy_settings()
        payload = await proxy_payload(request)
        try:
            url = settings.proxy_for_test(payload)
        except ProxySettingsError as error:
            raise proxy_http_error(error) from None

        def probe():
            from proxy_transport import probe_proxy

            if not settings.test_lock.acquire(blocking=False):
                raise HTTPException(
                    status_code=409,
                    detail={
                        "code": "proxy_test_busy",
                        "message": "A proxy connection test is already running.",
                    },
                )
            try:
                elapsed = probe_proxy(url, timeout=10)
                return {
                    "ok": True,
                    "elapsed_ms": elapsed,
                    "message": "The proxy reached the HTTPS test endpoint. This does not verify website login or download permissions.",
                }
            except Exception:  # noqa: BLE001 -- Do not expose transport credentials or diagnostics.
                # Network errors may contain credentials. Return only a fixed message.
                return {
                    "ok": False,
                    "code": "proxy_test_failed",
                    "message": "The proxy could not reach the HTTPS test endpoint. Check the address, protocol, port, authentication, and trusted certificates.",
                }
            finally:
                settings.test_lock.release()

        return await run_in_threadpool(probe)

    application.mount("/native", StaticFiles(directory=assets), name="desktop-assets")
    application.add_middleware(UpdateMaintenanceMiddleware, maintenance=maintenance)
    application.add_middleware(DesktopSessionMiddleware, token=token, origin=origin)
    return application
