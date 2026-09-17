from __future__ import annotations

import json
import math
import os
import selectors
import subprocess
import tempfile
import time
from pathlib import Path

from .common import PipelineError, check_cancelled

REMOTE_FORMATS = "mov,matroska,webm,ogg,mp3,wav,flac"
REMOTE_FORMAT_NAMES = {"mov", "mp4", "m4a", "3gp", "3g2", "mj2", "matroska", "webm", "ogg", "mp3", "wav", "flac"}


def remote_input_options(restricted: bool) -> list[str]:
    # Remote audio is inert media, never a playlist that can open other URLs or
    # local files. Keep the existing local-video pipeline unrestricted.
    return ["-protocol_whitelist", "file", "-format_whitelist", REMOTE_FORMATS] if restricted else []


def probe(path: Path, ffprobe: str, *, require_video: bool = True, restricted: bool = False) -> dict:
    result = subprocess.run([ffprobe, *remote_input_options(restricted), "-v", "error", "-show_streams", "-show_format",
                             "-of", "json", str(path)], capture_output=True, text=True, timeout=60, check=False)
    if result.returncode:
        raise PipelineError("Cannot inspect the selected media: " + result.stderr[-1500:].strip())
    payload = json.loads(result.stdout)
    video = [s for s in payload.get("streams", []) if s.get("codec_type") == "video"
             and not s.get("disposition", {}).get("attached_pic")]
    audio = [s for s in payload.get("streams", []) if s.get("codec_type") == "audio"]
    if restricted:
        formats = set(str(payload.get("format", {}).get("format_name", "")).split(","))
        if video or not formats or not formats.issubset(REMOTE_FORMAT_NAMES):
            raise PipelineError("The remote summary source must be audio in a supported inert container")
    if not video and require_video:
        raise PipelineError("The selected file has no video stream")
    if not audio:
        raise PipelineError("The selected video has no audio track")
    payload["video"] = next((s for s in video if s.get("disposition", {}).get("default")), video[0] if video else {})
    payload["audio"] = audio
    payload["selected_audio"] = next((s for s in audio if s.get("disposition", {}).get("default")), audio[0])
    try:
        duration = float(payload.get("format", {}).get("duration", (payload["video"] or payload["selected_audio"]).get("duration", 0)))
    except (ValueError, TypeError):
        duration = 0
    if not math.isfinite(duration) or duration <= 0:
        raise PipelineError("The selected video must have a finite positive duration")
    payload["duration"] = duration
    return payload


def run_ffmpeg(command: list[str], duration: float, callback, cancelled, cwd: Path) -> None:
    """Drain progress and bounded diagnostic storage without blocking cancellation."""
    command = [command[0], "-hide_banner", "-nostdin", "-loglevel", "warning",
               "-progress", "pipe:1", "-nostats", *command[1:]]
    with tempfile.TemporaryFile(mode="w+b") as diagnostics:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=diagnostics, cwd=cwd)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        buffer = b""
        started = time.monotonic()
        try:
            while selector.get_map():
                check_cancelled(cancelled)
                for key, _ in selector.select(timeout=0.2):
                    data = os.read(key.fileobj.fileno(), 65536)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    buffer += data
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        if line.startswith(b"out_time_us="):
                            try:
                                seconds = float(line.split(b"=", 1)[1]) / 1_000_000
                            except ValueError:
                                continue
                            fraction = min(1.0, max(0.0, seconds / duration))
                            eta = ((time.monotonic() - started) * (1 - fraction) / fraction
                                   if fraction > 0.01 else None)
                            callback(fraction, eta)
            code = process.wait(timeout=30)
            check_cancelled(cancelled)
            if code:
                diagnostics.seek(0, os.SEEK_END)
                diagnostics.seek(max(0, diagnostics.tell() - 4000))
                detail = diagnostics.read().decode("utf-8", errors="replace").strip()
                raise PipelineError("FFmpeg failed: " + (detail or str(code)))
        finally:
            selector.close()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
            process.stdout.close()


def extract_audio(source: Path, destination: Path, info: dict, ffmpeg: str, progress, cancelled, *, restricted: bool = False) -> None:
    command = [ffmpeg, "-n", *remote_input_options(restricted), "-i", str(source), "-map", f"0:{info['selected_audio']['index']}",
               "-vn", "-af", "aresample=async=1:first_pts=0", "-ar", "16000", "-ac", "1",
               "-c:a", "pcm_s16le", str(destination)]
    run_ffmpeg(command, info["duration"],
               lambda fraction, eta: progress.report("extracting", 0.02 + 0.07 * fraction,
                                                     "Preparing a temporary speech-analysis audio track", eta),
               cancelled, destination.parent)


def validate_burn_source(info: dict) -> None:
    video = info["video"]
    if video.get("color_transfer") in {"smpte2084", "arib-std-b67"} or video.get("color_primaries") == "bt2020":
        raise PipelineError("HDR / wide-gamut subtitle burn-in is not safely supported. Use the generated external subtitles.")
    for data in video.get("side_data_list", []):
        name = str(data.get("side_data_type", "")).lower()
        if any(word in name for word in ("dovi", "dolby", "hdr", "mastering", "content light", "display matrix")):
            raise PipelineError("This video's HDR or display-matrix metadata cannot be safely burned in. External subtitles were preserved.")
    if str(video.get("tags", {}).get("rotate", "0")) not in {"0", "0.0", ""}:
        raise PipelineError("Videos with rotation metadata require external subtitles to preserve their geometry")
    if video.get("field_order", "unknown") not in {"progressive", "unknown"}:
        raise PipelineError("Interlaced video requires external subtitles to preserve its field structure")
    supported = {f"yuv{chroma}p{suffix}" for chroma in ("420", "422", "444")
                 for suffix in ("", "10le", "12le", "16le")}
    if video.get("pix_fmt") not in supported:
        raise PipelineError("This pixel format has not been validated for lossless subtitle burn-in. External subtitles were preserved.")


def burn_subtitles(source: Path, destination: Path, info: dict, ffmpeg: str,
                   ffprobe: str, progress, cancelled) -> None:
    validate_burn_source(info)
    # Inspect decoded frame metadata too: some HDR metadata is not on the stream.
    scan = subprocess.run([ffprobe, "-v", "error", "-select_streams", str(info["video"]["index"]),
                           "-read_intervals", "%+#8", "-show_frames", "-of", "json", str(source)],
                          capture_output=True, text=True, timeout=60, check=False)
    if scan.returncode:
        raise PipelineError("Cannot verify decoded video color metadata for safe subtitle burn-in")
    for frame in json.loads(scan.stdout).get("frames", []):
        validate_burn_source({"video": {**info["video"], **frame}})
    video = info["video"]
    command = [ffmpeg, "-n", "-noautorotate", "-i", str(source), "-map", f"0:{video['index']}",
               "-map", "0:a?", "-map_metadata", "0", "-map_chapters", "0",
               "-vf", "ass=filename=subtitles.ass", "-c:v", "ffv1", "-level", "3", "-g", "1",
               "-pix_fmt", "+" + video["pix_fmt"], "-fps_mode", "passthrough", "-c:a", "copy"]
    for key, option in (("color_range", "-color_range"), ("color_space", "-colorspace"),
                        ("color_transfer", "-color_trc"), ("color_primaries", "-color_primaries"),
                        ("chroma_location", "-chroma_sample_location")):
        if video.get(key) not in {None, "unknown", "unspecified"}:
            command.extend([option, str(video[key])])
    command.append(str(destination))
    progress.report("burning", 0.94, "Burning subtitles to lossless FFV1 MKV; all original audio tracks are copied. Output may be very large.")
    run_ffmpeg(command, info["duration"],
               lambda fraction, eta: progress.report("burning", 0.94 + 0.059 * fraction,
                                                     "Writing lossless video and copying original audio", eta),
               cancelled, destination.parent)
    actual = probe(destination, ffprobe)
    for key in ("width", "height", "pix_fmt", "sample_aspect_ratio"):
        expected = video.get(key)
        if expected not in {None, "N/A"} and actual["video"].get(key) != expected:
            raise PipelineError(f"Burned video failed preservation verification: {key}")
    for key in ("color_range", "color_space", "color_transfer", "color_primaries", "chroma_location"):
        if video.get(key) not in {None, "unknown", "unspecified"} and actual["video"].get(key) != video[key]:
            raise PipelineError(f"Burned video failed color preservation verification: {key}")
    fields = ("codec_name", "sample_rate", "channels", "channel_layout")
    expected_audio = [tuple(stream.get(key) for key in fields) for stream in info["audio"]]
    actual_audio = [tuple(stream.get(key) for key in fields) for stream in actual["audio"]]
    if actual_audio != expected_audio:
        raise PipelineError("Burned video failed audio preservation verification")
