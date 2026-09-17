"""Acquire one public video source for local summarization, without a web service.

The parent sends one {id, source_url} JSON line and keeps stdin open. EOF, any
further input, or SIGTERM cancels this process and its exclusively owned group.
Only fixed diagnostics cross IPC; website errors and credentials never do.
"""

from __future__ import annotations

import contextlib
import copy
import fcntl
import html
import json
import math
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urljoin, urlsplit, urlunsplit

MAX_REQUEST = 16_384
MAX_BODY = 8 * 1024 * 1024
MAX_SEGMENTS = 100_000
MAX_TEXT = 2_000_000
MAX_DURATION = 24 * 60 * 60
MAX_AUDIO = 8 * 1024**3
CAPTION_DOMAINS = ("youtube.com", "googlevideo.com", "bilibili.com", "hdslb.com")
AUDIO_EXTENSIONS = {"m4a", "webm", "opus", "ogg", "mp3", "mp4", "wav", "flac"}
AUDIO_DEMUXERS = "mov,matroska,webm,ogg,mp3,wav,flac"
AUDIO_FORMAT_NAMES = {
    "mov,mp4,m4a,3gp,3g2,mj2",
    "matroska,webm",
    "ogg",
    "mp3",
    "wav",
    "flac",
}
MESSAGES = {
    "invalid_request": "Provide one valid request with a supported single-video URL.",
    "unsupported_source": "Only individual, non-live Bilibili and YouTube videos are supported.",
    "invalid_paths": "The private job folder or bundled media tools are unavailable.",
    "job_conflict": "This job folder belongs to another source or is already in use.",
    "configuration_unavailable": "Saved download settings cannot be read safely.",
    "cookies_unavailable": "The selected Chrome login data could not be read. Check the Chrome profile in the download center, or disable Chrome login there to try public content anonymously.",
    "authentication_required": "The website requires a valid login. Check the download center login settings.",
    "source_unavailable": "The website source could not be acquired. Check network, proxy, and access permissions.",
    "audio_unavailable": "No usable audio-only stream is available for this video.",
    "limit_exceeded": "The source exceeds the supported size or duration limits.",
    "cancelled": "Source acquisition cancelled; partial job downloads were retained.",
    "timeout": "Source acquisition timed out; partial job downloads were retained.",
}


class SourceError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(MESSAGES[code])


def number(value):
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def source_url(value):
    if (
        not isinstance(value, str)
        or len(value) > 4096
        or any(ord(c) <= 32 for c in value)
        or "\\" in value
    ):
        raise SourceError("invalid_request")
    try:
        parsed = urlsplit(value)
        host = (parsed.hostname or "").lower()
        if (
            parsed.scheme not in {"http", "https"}
            or parsed.username is not None
            or parsed.password is not None
            or parsed.port not in {None, 80, 443}
        ):
            raise ValueError
        query = parse_qs(parsed.query, max_num_fields=40)
        if host in {"youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"}:
            if host == "youtu.be":
                identifier = parsed.path.strip("/")
            elif parsed.path == "/watch":
                identifier = (
                    query.get("v", [""])[0] if len(query.get("v", [])) == 1 else ""
                )
            elif re.fullmatch(r"/(?:shorts|embed)/[A-Za-z0-9_-]{11}/?", parsed.path):
                identifier = parsed.path.split("/")[2]
            else:
                raise ValueError
            if not re.fullmatch(r"[A-Za-z0-9_-]{11}", identifier):
                raise ValueError
            return f"https://www.youtube.com/watch?v={identifier}", "youtube"
        if host in {"bilibili.com", "www.bilibili.com", "m.bilibili.com"}:
            match = re.fullmatch(
                r"/video/(BV[A-Za-z0-9]{10}|av[0-9]{1,20})/?", parsed.path
            )
            if not match:
                raise ValueError
            page = query.get("p", ["1"])
            if len(page) != 1 or not re.fullmatch(r"[1-9][0-9]{0,3}", page[0]):
                raise ValueError
            suffix = "?" + urlencode({"p": page[0]}) if page[0] != "1" else ""
            return f"https://www.bilibili.com/video/{match[1]}{suffix}", "bilibili"
        if host == "b23.tv" and re.fullmatch(r"/[A-Za-z0-9]{1,32}/?", parsed.path):
            return urlunsplit(("https", "b23.tv", parsed.path, "", "")), "bilibili"
    except (ValueError, UnicodeError):
        pass
    raise SourceError("unsupported_source")


def request_from_line(line):
    try:
        if len(line) > MAX_REQUEST or not line.endswith(b"\n"):
            raise ValueError
        request = json.loads(line)
        if not isinstance(request, dict) or set(request) != {"id", "source_url"}:
            raise ValueError
        identifier = request["id"]
        if not isinstance(identifier, str) or not re.fullmatch(
            r"[A-Za-z0-9_-]{1,80}", identifier
        ):
            raise ValueError
        try:
            url, platform = source_url(request["source_url"])
        except SourceError as error:
            error.request_id = identifier
            raise
        return identifier, url, platform
    except (ValueError, UnicodeError, TypeError):
        raise SourceError("invalid_request") from None


def read_private_json(path, maximum=65_536):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    except OSError:
        raise SourceError("configuration_unavailable") from None
    try:
        with os.fdopen(descriptor, "rb") as handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
                raise ValueError
            result = json.loads(handle.read(maximum + 1))
        if not isinstance(result, dict):
            raise TypeError
        return result
    except (OSError, ValueError, TypeError, UnicodeError):
        raise SourceError("configuration_unavailable") from None


def validate_paths(args):
    try:
        for name in ("data_dir", "download_dir", "ffmpeg", "ffprobe"):
            path = getattr(args, name)
            if not path.is_absolute() or path.is_symlink():
                raise ValueError
            setattr(args, name, path.resolve(strict=True))
        if not args.data_dir.is_dir() or not args.download_dir.is_dir():
            raise ValueError
        job = args.download_dir
        if (
            job in {Path(job.anchor), Path.home(), args.data_dir}
            or args.data_dir.is_relative_to(job)
            or any(part.lower().endswith(".app") for part in job.parts)
        ):
            raise ValueError
        if job.stat().st_uid != os.getuid():
            raise ValueError
        for child in job.iterdir():
            if child.is_symlink() or not child.is_file():
                raise ValueError
        job.chmod(0o700)
        if args.ffmpeg.parent != args.ffprobe.parent:
            raise ValueError
        if not all(
            path.is_file() and os.access(path, os.X_OK)
            for path in (args.ffmpeg, args.ffprobe)
        ):
            raise ValueError
    except (OSError, ValueError, RuntimeError):
        raise SourceError("invalid_paths") from None


@contextlib.contextmanager
def job_lock(job, url):
    descriptor = os.open(
        job / ".summary.lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600
    )
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise SourceError("job_conflict")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise SourceError("job_conflict") from None
        marker = job / ".summary-source.json"
        existing = read_private_json(marker)
        if existing is not None and existing != {"source_url": url}:
            raise SourceError("job_conflict")
        if existing is None:
            atomic_json(marker, {"source_url": url})
        yield
    finally:
        os.close(descriptor)


def atomic_json(destination, payload):
    descriptor, name = tempfile.mkstemp(
        prefix=".summary-", suffix=".tmp", dir=destination.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, allow_nan=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, destination)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(name)


def clean_text(value, maximum=20_000):
    if not isinstance(value, str) or len(value) > maximum:
        raise ValueError("Invalid text")
    value = html.unescape(re.sub(r"<[^>]{0,1024}>", "", value))
    return " ".join(
        "".join(
            c
            for c in value
            if c in "\n\t" or not unicodedata.category(c).startswith("C")
        ).split()
    )


def timestamp(value):
    if not re.fullmatch(r"(?:[0-9]{1,3}:)?[0-5][0-9]:[0-5][0-9][.,][0-9]{3}", value):
        raise ValueError("Invalid timestamp")
    result = 0.0
    for part in value.replace(",", ".").split(":"):
        result = result * 60 + float(part)
    return result


def parse_captions(raw, extension, duration):
    """Return complete bounded cues, or reject the entire caption track."""
    if (
        extension not in {"json", "json3", "vtt", "srt"}
        or len(raw) > MAX_BODY
        or not number(duration)
        or duration <= 0
    ):
        raise ValueError("Invalid captions")
    text = raw.decode("utf-8-sig", errors="strict").strip()
    if not text or text.startswith(("#EXTM3U", "<")):
        raise ValueError("Not captions")
    cues = []
    if extension in {"json3", "json"} or text.startswith("{"):
        payload = json.loads(text)
        if isinstance(payload, dict) and isinstance(payload.get("body"), list):
            if len(payload["body"]) > MAX_SEGMENTS or not all(
                isinstance(item, dict) for item in payload["body"]
            ):
                raise ValueError("Too many cues")
            cues = [
                (item.get("from"), item.get("to"), item.get("content"))
                for item in payload["body"]
                if isinstance(item, dict)
            ]
        elif isinstance(payload, dict) and isinstance(payload.get("events"), list):
            events = payload["events"]
            if len(events) > MAX_SEGMENTS:
                raise ValueError("Too many cues")
            for index, event in enumerate(events):
                if not isinstance(event, dict) or not event.get("segs"):
                    continue
                start, length = event.get("tStartMs"), event.get("dDurationMs")
                if not number(start):
                    raise ValueError("Missing time")
                end = (
                    start + length
                    if number(length)
                    else (
                        events[index + 1].get("tStartMs")
                        if index + 1 < len(events)
                        and isinstance(events[index + 1], dict)
                        else None
                    )
                )
                if not number(end):
                    raise ValueError("Missing time")
                parts = event["segs"]
                if not isinstance(parts, list) or len(parts) > MAX_SEGMENTS:
                    raise ValueError("Invalid cue")
                words = "".join(
                    part.get("utf8", "") for part in parts if isinstance(part, dict)
                )
                cues.append((start / 1000, end / 1000, words))
        else:
            raise ValueError("Unknown captions")
    else:
        if extension == "vtt" and not text.startswith("WEBVTT"):
            raise ValueError("Not WebVTT")
        for block in re.split(r"\r?\n\s*\r?\n", text):
            lines = block.splitlines()
            timing = next(
                (i for i, line in enumerate(lines[:2]) if " --> " in line), None
            )
            if timing is None:
                if extension == "vtt" and block.startswith(
                    ("WEBVTT", "NOTE", "STYLE", "REGION")
                ):
                    continue
                raise ValueError("Malformed cue")
            if extension == "srt" and timing != 0 and not lines[0].isdigit():
                raise ValueError("Invalid SubRip cue")
            match = re.fullmatch(r"(\S+)\s+-->\s+(\S+)(?:\s+.*)?", lines[timing])
            if not match:
                raise ValueError("Invalid cue")
            cues.append(
                (
                    timestamp(match[1]),
                    timestamp(match[2]),
                    " ".join(lines[timing + 1 :]),
                )
            )
            if len(cues) > MAX_SEGMENTS:
                raise ValueError("Too many cues")
    segments, characters = [], 0
    previous_start = -1.0
    for start, end, words in cues:
        if (
            not number(start)
            or not number(end)
            or not 0 <= start < end <= duration + 5
            or start >= duration
            or start < previous_start
        ):
            raise ValueError("Invalid cue time")
        previous_start = start
        words = clean_text(words)
        if not words:
            continue
        if words.startswith(("http://", "https://", "#EXT")):
            raise ValueError("Playlist text")
        if segments and start <= segments[-1]["end"] + 1:
            previous = segments[-1]
            if words == previous["source_text"] or words.startswith(
                previous["source_text"]
            ):
                previous.update(
                    end=min(duration, max(end, previous["end"])), source_text=words
                )
                continue
            # Rolling captions often repeat the previous suffix before new words.
            for size in range(
                min(1024, len(words), len(previous["source_text"])), 3, -1
            ):
                if previous["source_text"].endswith(words[:size]):
                    words = words[size:].strip()
                    break
        if words:
            segments.append(
                {"start": start, "end": min(end, duration), "source_text": words}
            )
            characters += len(words)
        if characters > MAX_TEXT:
            raise ValueError("Too much text")
    if (
        not segments
        or segments[0]["start"] > max(10, duration * 0.1)
        or segments[-1]["end"] < duration * 0.85
    ):
        raise ValueError("Partial captions")
    # Sparse speech is valid, but a tiny intro plus a final cue is not coverage.
    covered, edge = 0.0, 0.0
    for segment in segments:
        covered += max(0, segment["end"] - max(edge, segment["start"]))
        edge = max(edge, segment["end"])
    if (
        covered < duration * 0.25
        or not 2 <= sum(len(item["source_text"]) for item in segments) <= MAX_TEXT
    ):
        raise ValueError("Insufficient caption coverage")
    return segments


def caption_url(value):
    try:
        if (
            not isinstance(value, str)
            or len(value) > 16_384
            or any(ord(c) <= 32 for c in value)
            or "\\" in value
        ):
            raise ValueError
        parsed = urlsplit(value)
        host = (parsed.hostname or "").lower()
        if (
            parsed.scheme != "https"
            or parsed.username is not None
            or parsed.password is not None
            or parsed.port not in {None, 443}
        ):
            raise ValueError
        if not any(
            host == domain or host.endswith("." + domain) for domain in CAPTION_DOMAINS
        ):
            raise ValueError
        return value
    except (ValueError, UnicodeError):
        raise ValueError("Untrusted caption URL") from None


def caption_tracks(info):
    original = str(info.get("language") or "").lower().split("-")[0]
    tracks = []
    for automatic, field in enumerate(("subtitles", "automatic_captions")):
        pool = info.get(field) or {}
        if not isinstance(pool, dict) or len(pool) > 1000:
            continue
        for language, formats in pool.items():
            if not isinstance(formats, list):
                continue
            for track in formats[:12]:
                if not isinstance(track, dict) or track.get("ext") not in {
                    "json3",
                    "vtt",
                    "json",
                    "srt",
                }:
                    continue
                try:
                    if "data" in track:
                        if (
                            not isinstance(track["data"], str)
                            or len(track["data"]) > MAX_BODY
                        ):
                            continue
                    else:
                        url = caption_url(track.get("url"))
                        if parse_qs(urlsplit(url).query, max_num_fields=80).get(
                            "tlang"
                        ):
                            continue
                except ValueError:
                    continue
                source = str(language).lower().split("-")[0] == original or str(
                    language
                ).endswith("-orig")
                tracks.append(
                    (
                        (
                            not source,
                            automatic,
                            {"json3": 0, "json": 1, "vtt": 2, "srt": 3}[track["ext"]],
                        ),
                        track,
                    )
                )
    return [item for _, item in sorted(tracks, key=lambda item: item[0])][:8]


def fetch_caption(session, url, check):
    for _ in range(5):
        check()
        url = caption_url(url)
        with session.get(
            url, allow_redirects=False, stream=True, timeout=(10, 20)
        ) as response:
            if response.status_code in {301, 302, 303, 307, 308}:
                url = urljoin(url, response.headers.get("Location", ""))
                continue
            if response.status_code != 200:
                raise ValueError("Caption unavailable")
            data = bytearray()
            for chunk in response.iter_content(65_536):
                check()
                data.extend(chunk)
                if len(data) > MAX_BODY:
                    raise ValueError("Caption too large")
            return bytes(data)
    raise ValueError("Caption redirect limit")


class QuietLogger:
    def debug(self, *_):
        pass

    info = warning = error = debug


class Cancellation:
    def __init__(self, timeout=4 * 60 * 60):
        self.event = threading.Event()
        self.deadline = time.monotonic() + timeout
        self.code = "cancelled"

    def request(self, code="cancelled"):
        if not self.event.is_set():
            self.code = code
            self.event.set()

    def check(self):
        if time.monotonic() >= self.deadline:
            self.request("timeout")
        if self.event.is_set():
            raise SourceError(self.code)


def validate_audio(path, executable, expected_duration, control):
    control.check()
    try:
        result = subprocess.run(
            [
                str(executable),
                "-v",
                "error",
                "-max_alloc",
                "67108864",
                "-protocol_whitelist",
                "file",
                "-format_whitelist",
                AUDIO_DEMUXERS,
                "-show_entries",
                "format=duration,format_name:stream=codec_type",
                "-of",
                "json",
                str(path),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=30,
            check=False,
        )
        control.check()
        if result.returncode or len(result.stdout) > 1_048_576:
            raise ValueError
        info = json.loads(result.stdout)
        if info["format"].get("format_name") not in AUDIO_FORMAT_NAMES:
            raise ValueError
        duration = float(info["format"]["duration"])
        streams = info.get("streams", [])
        if not math.isfinite(duration) or abs(duration - expected_duration) > max(
            5, expected_duration * 0.05
        ):
            raise ValueError
        if not streams or any(item.get("codec_type") != "audio" for item in streams):
            raise ValueError
    except SourceError:
        raise
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError):
        raise SourceError("audio_unavailable") from None


def acquire(
    args,
    url,
    platform,
    emit,
    control,
    *,
    ydl_factory=None,
    session_factory=None,
    node=None,
):
    """Inject transport factories in tests; production reads only explicit saved settings."""
    from proxy_config import ProxySettings, ProxySettingsError
    from proxy_transport import _download_proxy

    settings = read_private_json(args.data_dir / "config.json") or {}
    # A first-time summary request must not require Chrome to be installed.
    # Only an explicitly saved opt-in may access the browser's login database.
    use_cookies = settings.get("use_chrome_cookies", False)
    profile = settings.get("chrome_profile")
    if (
        type(use_cookies) is not bool
        or profile is not None
        and (not isinstance(profile, str) or len(profile) > 1024 or "\0" in profile)
    ):
        raise SourceError("configuration_unavailable")
    try:
        proxy = ProxySettings(args.data_dir, None).proxy_url()
    except (ProxySettingsError, OSError, ValueError):
        raise SourceError("configuration_unavailable") from None
    if node is None:
        from js_runtime import node_path

        node = node_path()
    if ydl_factory is None:
        from yt_dlp import YoutubeDL

        ydl_factory = YoutubeDL
    if session_factory is None:
        import requests

        session_factory = requests.Session
    # Reuse the shipped extractor retry/cookie policy without importing app.main.
    from app.downloader import DownloaderConfig, MediaDownloader

    options = MediaDownloader(
        DownloaderConfig(
            cookie_browser="chrome" if use_cookies else None, cookie_profile=profile
        )
    )._base_options()
    options.update(
        {
            "logger": QuietLogger(),
            "quiet": True,
            "no_warnings": True,
            "verbose": False,
            "js_runtimes": {"node": {"path": str(node)}},
            "remote_components": [],
            "proxy": _download_proxy(proxy),
            "cachedir": False,
            "usenetrc": False,
            "socket_timeout": 20,
            "retries": 3,
            "fragment_retries": 3,
            "extractor_retries": 2,
            "noplaylist": True,
            "playlistend": 1,
            "format": "bestaudio",
            "noprogress": True,
            "ffmpeg_location": str(args.ffmpeg.parent),
            "outtmpl": str(args.download_dir / "audio.%(ext)s"),
            "continuedl": True,
            "overwrites": False,
            "nopart": False,
            "max_filesize": MAX_AUDIO,
            "concurrent_fragment_downloads": 1,
            "hls_prefer_native": True,
            "writethumbnail": False,
            "writeinfojson": False,
            "writesubtitles": False,
            # Bilibili only exposes caption data when this discovery flag is
            # enabled. Disable it before audio processing to prevent list-only
            # mode from short-circuiting the actual download.
            "listsubtitles": True,
            "simulate": False,
        }
    )
    last_progress = [0.0]

    def progress(status):
        control.check()
        count, total = (
            status.get("downloaded_bytes"),
            status.get("total_bytes") or status.get("total_bytes_estimate"),
        )
        if number(count) and count > MAX_AUDIO or number(total) and total > MAX_AUDIO:
            raise SourceError("limit_exceeded")
        now = time.monotonic()
        if now - last_progress[0] < 0.2 and status.get("status") != "finished":
            return
        last_progress[0] = now
        event = {
            "type": "progress",
            "stage": "downloading_audio",
            "message": "Downloading the audio-only stream.",
        }
        for key, value in (
            ("downloaded_bytes", count),
            ("total_bytes", total),
            ("bytes_per_second", status.get("speed")),
            ("eta_seconds", status.get("eta")),
        ):
            if number(value) and value >= 0:
                # Fragment download estimates may be fractional. Byte fields
                # are Int64 in the native protocol; rates and ETA stay Double.
                event[key] = (
                    math.ceil(value)
                    if key == "total_bytes"
                    else int(value)
                    if key == "downloaded_bytes"
                    else value
                )
        if number(count) and number(total) and total > 0:
            event["progress"] = min(0.99, max(0.0, count / total))
        emit(event)

    options["progress_hooks"] = [progress]
    control.check()
    emit(
        {
            "type": "progress",
            "stage": "reading_source",
            "message": "Reading video metadata and caption availability.",
        }
    )
    with ydl_factory(options) as ydl:
        # The browser reader returns a copy. Detach every cookie so only our
        # in-memory jar is mutated; no cookiefile or normal task state is written.
        from yt_dlp.cookies import YoutubeDLCookieJar

        private_jar = YoutubeDLCookieJar()
        try:
            cookies = ydl.cookiejar
        except SourceError:
            raise
        except Exception:  # noqa: BLE001 -- Browser failures may include private profile paths; emit only a fixed diagnostic.
            raise SourceError("cookies_unavailable") from None
        for cookie in cookies:
            private_jar.set_cookie(copy.copy(cookie))
        ydl.cookiejar = private_jar
        info = None
        extraction_url = url
        for _ in range(4):
            control.check()
            try:
                info = ydl.extract_info(extraction_url, download=False, process=False)
            except SourceError:
                raise
            except Exception:
                # Caption discovery can fail inside the platform extractor;
                # retry without captions before giving up on audio.
                if not ydl.params.get("listsubtitles"):
                    raise
                control.check()
                ydl.params["listsubtitles"] = False
                info = ydl.extract_info(extraction_url, download=False, process=False)
            if not isinstance(info, dict):
                raise SourceError("source_unavailable")
            if info.get("_type") not in {"url", "url_transparent"}:
                break
            extraction_url, redirected_platform = source_url(info.get("url"))
            if redirected_platform != platform:
                raise SourceError("unsupported_source")
        if (
            info.get("_type", "video") != "video"
            or "entries" in info
            or info.get("is_live")
            or info.get("live_status") not in {None, "not_live", "was_live"}
        ):
            raise SourceError("unsupported_source")
        if urlsplit(extraction_url).hostname == "b23.tv":
            extraction_url, resolved_platform = source_url(info.get("webpage_url"))
            if (
                resolved_platform != platform
                or urlsplit(extraction_url).hostname == "b23.tv"
            ):
                raise SourceError("unsupported_source")
        duration = info.get("duration")
        if not number(duration) or not 0 < duration <= MAX_DURATION:
            raise SourceError("limit_exceeded")
        identifier = info.get("id")
        if not isinstance(identifier, str) or not re.fullmatch(
            r"[A-Za-z0-9_-]{1,100}", identifier
        ):
            raise SourceError("source_unavailable")
        result = {
            "schema_version": 1,
            "title": clean_text(str(info.get("title") or "Untitled")[:2000], 2000)[
                :500
            ],
            "source_url": extraction_url,
            "platform": platform,
            "video_id": identifier,
            "duration": duration,
            "content_source": "subtitles",
            "segments": [],
            "warnings": [],
        }
        with session_factory() as session:
            session.trust_env = False
            session.proxies = (
                {"http": _download_proxy(proxy), "https": _download_proxy(proxy)}
                if proxy
                else {}
            )
            session.cookies.clear()
            for cookie in private_jar:
                session.cookies.set_cookie(copy.copy(cookie))
            session.headers.update(
                {"User-Agent": "Mozilla/5.0", "Referer": extraction_url}
            )
            for track in caption_tracks(info):
                control.check()
                emit(
                    {
                        "type": "progress",
                        "stage": "reading_source",
                        "message": "Validating caption text and timing coverage.",
                    }
                )
                try:
                    raw = (
                        track["data"].encode("utf-8")
                        if "data" in track
                        else fetch_caption(session, track["url"], control.check)
                    )
                    result["segments"] = parse_captions(raw, track["ext"], duration)
                    break
                except SourceError:
                    raise
                except Exception:  # noqa: BLE001, S112 -- An unusable track must fall back to audio without exposing remote diagnostics.
                    continue
        if not result["segments"]:
            result["content_source"] = "audio"
            result["warnings"] = [
                "No complete usable captions were available; local speech recognition is required."
            ]
            control.check()
            ydl.params["listsubtitles"] = False
            processed = ydl.process_ie_result(info, download=True)
            control.check()
            paths = [
                entry.get("filepath")
                for entry in (processed or {}).get("requested_downloads", [])
                if isinstance(entry, dict)
            ]
            if not paths:
                paths = [
                    str(path)
                    for path in args.download_dir.glob("audio.*")
                    if path.suffix.lstrip(".") in AUDIO_EXTENSIONS
                ]
            if len(paths) != 1 or not isinstance(paths[0], str):
                raise SourceError("audio_unavailable")
            audio = Path(paths[0])
            if (
                audio.is_symlink()
                or audio.resolve().parent != args.download_dir
                or audio.stem != "audio"
                or audio.suffix.lstrip(".") not in AUDIO_EXTENSIONS
                or not audio.is_file()
            ):
                raise SourceError("audio_unavailable")
            if not 0 < audio.stat().st_size <= MAX_AUDIO:
                raise SourceError("audio_unavailable")
            validate_audio(audio, args.ffprobe, duration, control)
            result["audio_path"] = str(audio.resolve())
    control.check()
    destination = args.download_dir / "source.json"
    atomic_json(destination, result)
    return destination


def main(args):
    original_output, errors = sys.stdout, sys.stderr
    # Keep protocol writes separate from fd 1, including for native libraries
    # and child processes that bypass Python's stdout object. Duplicates are
    # non-inheritable, so a downloader child cannot write into the IPC stream.
    output = os.fdopen(os.dup(original_output.fileno()), "w", encoding="utf-8")
    lock = threading.Lock()
    terminal = threading.Event()
    finished = threading.Event()
    control = Cancellation(timeout=30)
    identifier = ""

    def emit(event):
        with lock:
            if terminal.is_set():
                return
            if event.get("type") in {"failed", "completed"}:
                terminal.set()
            try:
                output.write(
                    json.dumps(
                        {**event, "id": identifier}, ensure_ascii=True, allow_nan=False
                    )
                    + "\n"
                )
                output.flush()
            except (OSError, ValueError):
                control.request()

    def watchdog():
        while not finished.wait(0.1):
            try:
                control.check()
            except SourceError as error:
                emit({"type": "failed", "code": error.code, "message": str(error)})
                # The group is verified before any untrusted work or child launch.
                os.killpg(os.getpid(), signal.SIGTERM)
                if not finished.wait(3):
                    os.killpg(os.getpid(), signal.SIGKILL)
                return

    def parent_watch():
        try:
            sys.stdin.buffer.read(1)
        finally:
            control.request()

    try:
        os.umask(0o077)
        try:
            os.setsid()
        except OSError:
            if os.getpgrp() != os.getpid():
                raise SourceError("invalid_paths") from None
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, lambda *_: control.request())
        threading.Thread(target=watchdog, daemon=True).start()
        identifier, url, platform = request_from_line(
            sys.stdin.buffer.readline(MAX_REQUEST + 1)
        )
        control.deadline = time.monotonic() + 4 * 60 * 60
        threading.Thread(target=parent_watch, daemon=True).start()
        # Third-party libraries can write outside their logger. Never forward
        # that output: diagnostics may contain signed URLs or browser secrets.
        with open(os.devnull, "w") as muted:
            saved_stdout, saved_stderr = os.dup(1), os.dup(2)
            sys.stdout = sys.stderr = muted
            os.dup2(muted.fileno(), 1)
            os.dup2(muted.fileno(), 2)
            try:
                validate_paths(args)
                from helper import prepare_environment

                prepare_environment(args)
                with job_lock(args.download_dir, url):
                    source = acquire(args, url, platform, emit, control)
                emit({"type": "completed", "source_path": str(source)})
            finally:
                os.dup2(saved_stdout, 1)
                os.dup2(saved_stderr, 2)
                os.close(saved_stdout)
                os.close(saved_stderr)
        return 0
    except Exception as error:  # noqa: BLE001 -- Only fixed diagnostics may cross the subprocess boundary.
        identifier = getattr(error, "request_id", identifier)
        code = error.code if isinstance(error, SourceError) else "source_unavailable"
        if control.event.is_set():
            code = control.code
        elif not isinstance(error, SourceError) and re.search(
            r"sign in|login|cookies|authentication|members.only|private video",
            str(error),
            re.IGNORECASE,
        ):
            code = "authentication_required"
        emit({"type": "failed", "code": code, "message": MESSAGES[code]})
        return 1
    finally:
        finished.set()
        sys.stdout, sys.stderr = original_output, errors
        output.close()
