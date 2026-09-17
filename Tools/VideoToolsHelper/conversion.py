from __future__ import annotations

import contextlib
import json
import math
import os
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from collections import deque
from dataclasses import dataclass, field
from fractions import Fraction
from pathlib import Path
from typing import Any

from media import (
    MediaError,
    RotationManager,
    VideoSource,
    _estimated_progress_remaining_seconds,
    _optional_finite_float,
    _parse_aspect_ratio,
    _remove_owned_file,
    _run_capture,
    available_output_path,
    probe_video,
    safe_output_stem,
)

SUPPORTED_CONVERSION_FORMATS = frozenset({"mp4", "mkv", "mov"})
SUPPORTED_CONVERSION_MODES = frozenset({"copy", "h264", "hevc"})

# These intentionally conservative lists prevent implicit track loss or transcoding.
_VIDEO_CODECS = {
    "mp4": {"h264", "hevc", "av1", "mpeg4", "mpeg2video", "mjpeg"},
    "mov": {"h264", "hevc", "mpeg4", "mpeg2video", "mjpeg", "prores", "qtrle"},
    "mkv": {
        "h264",
        "hevc",
        "av1",
        "vp8",
        "vp9",
        "mpeg4",
        "mpeg2video",
        "mpeg1video",
        "mjpeg",
        "ffv1",
        "prores",
        "theora",
        "huffyuv",
        "vc1",
        "wmv3",
    },
}
_AUDIO_CODECS = {
    "mp4": {"aac", "mp3", "ac3", "eac3", "alac"},
    "mov": {
        "aac",
        "mp3",
        "ac3",
        "eac3",
        "alac",
        "pcm_s8",
        "pcm_u8",
        "pcm_s16le",
        "pcm_s16be",
        "pcm_s24le",
        "pcm_s24be",
        "pcm_s32le",
        "pcm_s32be",
        "pcm_f32le",
        "pcm_f32be",
        "pcm_f64le",
        "pcm_f64be",
        "pcm_alaw",
        "pcm_mulaw",
    },
    "mkv": {
        "aac",
        "mp3",
        "mp2",
        "ac3",
        "eac3",
        "alac",
        "flac",
        "opus",
        "vorbis",
        "dts",
        "truehd",
        "mlp",
        "wavpack",
        "pcm_u8",
        "pcm_s16le",
        "pcm_s16be",
        "pcm_s24le",
        "pcm_s24be",
        "pcm_s32le",
        "pcm_s32be",
        "pcm_f32le",
        "pcm_f64le",
    },
}
_SUBTITLE_CODECS = {
    "mp4": {"mov_text"},
    "mov": {"mov_text"},
    "mkv": {"subrip", "ass", "ssa", "webvtt", "hdmv_pgs_subtitle", "dvd_subtitle"},
}
_COLOR_KEYS = ("color_range", "color_primaries", "color_transfer", "color_space")


@dataclass
class ConversionJob:
    id: str
    source: VideoSource
    target_format: str
    mode: str
    output_path: Path
    status: str = "queued"
    progress: float = 0.0
    message: str = "Waiting to convert"
    error: str | None = None
    created_at: float = field(default_factory=time.time)
    started_at: float | None = None
    encoding_started_at: float | None = None
    finished_at: float | None = None
    cancel_event: threading.Event = field(default_factory=threading.Event, repr=False)
    process: subprocess.Popen[str] | None = field(default=None, repr=False)
    worker: threading.Thread | None = field(default=None, repr=False)
    lock: threading.RLock = field(default_factory=threading.RLock, repr=False)

    def snapshot(self) -> dict[str, Any]:
        with self.lock:
            end = self.finished_at or time.time()
            elapsed = max(0.0, end - (self.started_at or self.created_at))
            encoding_elapsed = (
                max(0.0, end - self.encoding_started_at)
                if self.encoding_started_at is not None
                else 0.0
            )
            return {
                "job_id": self.id,
                "operation": "convert",
                "target_format": self.target_format,
                "mode": self.mode,
                "conversion_mode": self.mode,
                "status": self.status,
                "progress": round(self.progress, 1),
                "message": self.message,
                "output_name": self.output_path.name,
                "output_path": str(self.output_path)
                if self.status == "completed"
                else None,
                "error": self.error,
                "elapsed_seconds": round(elapsed, 1),
                "estimated_remaining_seconds": _estimated_progress_remaining_seconds(
                    status=self.status,
                    progress=self.progress,
                    elapsed_seconds=encoding_elapsed,
                    start_progress=5.0,
                ),
            }


class ConversionManager(RotationManager):
    """Convert containers or video codecs without dropping unsupported tracks."""

    def create(
        self,
        source: VideoSource,
        *,
        target_format: str,
        mode: str,
        output_directory: Path,
    ) -> ConversionJob:
        if (
            not isinstance(target_format, str)
            or target_format not in SUPPORTED_CONVERSION_FORMATS
        ):
            raise MediaError(
                "Unsupported conversion container; choose MP4, MKV, or MOV"
            )
        if not isinstance(mode, str) or mode not in SUPPORTED_CONVERSION_MODES:
            raise MediaError("Unsupported conversion mode; choose copy, h264, or hevc")
        if self.cancel_event is not None and self.cancel_event.is_set():
            raise InterruptedError
        if not source.path.is_file():
            raise MediaError("The original video was moved or deleted")
        source = VideoSource(
            source.id, source.path.expanduser().resolve(), source.metadata
        )
        directory = output_directory.expanduser().resolve()
        self._check_source_directory(directory)
        encoder = {"h264": "libx264", "hevc": "libx265"}.get(mode)
        if encoder is not None and encoder not in self.encoders:
            raise MediaError(f"Required FFmpeg encoder is not available: {encoder}")
        name = f"{safe_output_stem(source.path.stem)}_converted_{mode}.{target_format}"
        job = ConversionJob(
            id=uuid.uuid4().hex,
            source=source,
            target_format=target_format,
            mode=mode,
            output_path=available_output_path(directory, name),
        )
        with self._lock:
            self._jobs[job.id] = job
        try:
            job.worker = threading.Thread(
                target=self._run_conversion, args=(job,), daemon=True
            )
            job.worker.start()
        except Exception as exc:
            with self._lock:
                self._jobs.pop(job.id, None)
            job.worker = None
            raise MediaError("Could not start conversion worker") from exc
        return job

    def get(self, job_id: str) -> ConversionJob | None:
        with self._lock:
            return self._jobs.get(job_id)

    def cancel(self, job_id: str) -> ConversionJob:
        job = self.get(job_id)
        if job is None:
            raise MediaError("Conversion job was not found")
        with job.lock:
            if job.status not in {"queued", "running"}:
                return job
            job.cancel_event.set()
            process = job.process
            job.message = "Cancelling and removing the partial conversion"
        if process is not None and process.poll() is None:
            self._request_process_stop(process)
            threading.Thread(
                target=self._escalate_process_stop,
                args=(process,),
                daemon=True,
            ).start()
        return job

    def _inventory(self, path: Path, cancel_event: threading.Event) -> dict[str, Any]:
        try:
            completed = _run_capture(
                [
                    self.ffprobe,
                    "-v",
                    "error",
                    "-show_streams",
                    "-show_chapters",
                    "-show_format",
                    "-show_data_hash",
                    "sha256",
                    "-of",
                    "json",
                    str(path),
                ],
                timeout=60,
                cancel_event=cancel_event,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise MediaError(f"Could not inspect every media track: {exc}") from exc
        if completed.returncode != 0:
            raise MediaError("Could not inspect every media track")
        try:
            result = json.loads(completed.stdout)
        except json.JSONDecodeError as exc:
            raise MediaError("FFprobe returned invalid track metadata") from exc
        if not isinstance(result, dict) or not isinstance(result.get("streams"), list):
            raise MediaError("FFprobe returned invalid track metadata")
        if not all(isinstance(stream, dict) for stream in result["streams"]):
            raise MediaError("FFprobe returned invalid track metadata")
        return result

    @staticmethod
    def _tracks(
        inventory: dict[str, Any],
        *,
        allow_generated_chapter_track: bool = False,
    ) -> list[dict[str, Any]]:
        # Only the verified output may contain a chapter track generated by this
        # conversion. Input data tracks remain unsupported instead of being guessed.
        return [
            stream
            for stream in inventory["streams"]
            if not (
                allow_generated_chapter_track
                and inventory.get("chapters")
                and stream.get("codec_type") == "data"
                and stream.get("codec_name") == "bin_data"
                and stream.get("codec_tag_string") == "text"
            )
        ]

    def _validate_tracks(self, job: ConversionJob, inventory: dict[str, Any]) -> None:
        if job.source.metadata.get("is_dolby_vision") or job.source.metadata.get(
            "dynamic_hdr_metadata_types"
        ):
            raise MediaError(
                "Dynamic HDR container metadata cannot be preserved safely"
            )
        tracks = self._tracks(inventory)
        videos = [stream for stream in tracks if stream.get("codec_type") == "video"]
        if len(videos) != 1 or any(
            (stream.get("disposition") or {}).get("attached_pic") for stream in videos
        ):
            raise MediaError(
                "Multiple video tracks or cover-art streams cannot be converted safely; "
                "no track has been removed"
            )
        for stream in tracks:
            kind = stream.get("codec_type")
            codec = str(stream.get("codec_name") or "unknown")
            if kind == "video":
                codec = codec if job.mode == "copy" else job.mode
                allowed = _VIDEO_CODECS[job.target_format]
            elif kind == "audio":
                allowed = _AUDIO_CODECS[job.target_format]
            elif kind == "subtitle":
                allowed = _SUBTITLE_CODECS[job.target_format]
            elif kind == "attachment":
                if job.target_format == "mkv" and all(
                    (stream.get("tags") or {}).get(key)
                    for key in ("filename", "mimetype")
                ):
                    continue
                raise MediaError(
                    "Attachments require MKV and complete filename/MIME metadata"
                )
            else:
                raise MediaError(
                    f"Unsupported {kind or 'unknown'} track {stream.get('index')}; "
                    "conversion will not silently remove it"
                )
            if codec not in allowed:
                raise MediaError(
                    f"{job.target_format.upper()} cannot safely preserve {kind} track "
                    f"{stream.get('index')} ({codec}). Choose another container or video "
                    "encoding mode; audio and subtitles are never silently transcoded or removed"
                )
        if job.mode != "copy":
            self._encoding_options(job)

    def _encoding_options(self, job: ConversionJob) -> list[str]:
        if job.mode == "copy":
            return []
        source = job.source
        metadata = source.metadata
        if metadata.get("is_dolby_vision") or metadata.get(
            "dynamic_hdr_metadata_types"
        ):
            raise MediaError(
                "Dynamic HDR cannot be re-encoded safely; use lossless container copy"
            )
        if not metadata.get("hdr_metadata_inspected"):
            raise MediaError("Frame color metadata could not be inspected safely")
        if (
            metadata.get("has_alpha")
            or metadata.get("is_rgb")
            or metadata.get("is_palette")
        ):
            raise MediaError("Alpha or RGB video requires lossless container copy")
        if metadata.get("field_order") not in {"", "unknown", "progressive", None}:
            raise MediaError("Interlaced video requires lossless container copy")
        depth = int(metadata.get("video_bit_depth") or 0)
        if depth <= 0 or (job.mode == "h264" and (depth > 8 or metadata.get("is_hdr"))):
            raise MediaError(
                "High-bit-depth or HDR video requires HEVC or lossless container copy"
            )
        if depth > 12:
            raise MediaError("Video above 12 bits requires lossless container copy")
        encoder = "libx264" if job.mode == "h264" else "libx265"
        pixel_format = str(metadata.get("pix_fmt") or "")
        if not metadata.get(
            "pixel_format_known"
        ) or pixel_format not in self._supported_pixel_formats(
            encoder,
        ):
            raise MediaError(
                f"{encoder} cannot preserve the source pixel format ({pixel_format})"
            )
        options = [
            "-c:v:0",
            encoder,
            "-preset:v:0",
            "slow",
            "-crf:v:0",
            "18",
            "-pix_fmt:v:0",
            f"+{pixel_format}",
            "-fps_mode:v:0",
            "passthrough",
            "-enc_time_base:v:0",
            "demux",
            *self._color_options(source),
        ]
        if job.mode == "hevc":
            options.extend(self._x265_hdr_options(source))
            if job.target_format in {"mp4", "mov"}:
                options.extend(["-tag:v:0", "hvc1"])
        chroma = str(metadata.get("chroma_location") or "")
        if chroma and chroma != "unspecified":
            options.extend(["-chroma_sample_location:v:0", chroma])
        return options

    def _command(
        self,
        job: ConversionJob,
        temporary_path: Path,
        inventory: dict[str, Any],
    ) -> list[str]:
        command = [
            self.ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-y",
            "-noautorotate",
            "-copyts",
            "-i",
            str(job.source.path),
        ]
        for stream in self._tracks(inventory):
            command.extend(["-map", f"0:{int(stream['index'])}"])
        command.extend(
            [
                "-map_metadata",
                "0",
                "-map_chapters",
                "0",
                "-c",
                "copy",
                "-avoid_negative_ts",
                "disabled",
                *self._encoding_options(job),
            ]
        )
        for index, stream in enumerate(self._tracks(inventory)):
            disposition = (
                "+".join(
                    name
                    for name, enabled in (stream.get("disposition") or {}).items()
                    if enabled
                )
                or "0"
            )
            command.extend([f"-disposition:{index}", disposition])
        if job.target_format in {"mp4", "mov"}:
            command.extend(["-movflags", "+faststart"])
        command.extend(
            [
                "-progress",
                "pipe:1",
                "-stats_period",
                "0.2",
                "-nostats",
                "-f",
                "matroska" if job.target_format == "mkv" else job.target_format,
                str(temporary_path),
            ]
        )
        return command

    @staticmethod
    def _identity(path: Path) -> tuple[int, int, int, int]:
        stat = path.stat()
        return stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns

    def _verify_conversion(
        self,
        job: ConversionJob,
        temporary_path: Path,
        original: dict[str, Any],
    ) -> None:
        result = probe_video(
            temporary_path, ffprobe=self.ffprobe, cancel_event=job.cancel_event
        )
        source = job.source.metadata
        for key in (
            "width",
            "height",
            "encoded_width",
            "encoded_height",
            "rotation",
            "pix_fmt",
        ):
            if source.get(key) != result.get(key):
                raise MediaError(f"Output verification detected changed {key}")
        expected_codec = source["video_codec"] if job.mode == "copy" else job.mode
        if result["video_codec"] != expected_codec:
            raise MediaError("Output verification detected an unexpected video codec")
        if (
            _parse_aspect_ratio(source.get("sample_aspect_ratio")) or Fraction(1, 1)
        ) != (_parse_aspect_ratio(result.get("sample_aspect_ratio")) or Fraction(1, 1)):
            raise MediaError(
                "Output verification detected a sample aspect ratio change"
            )
        for key in (*_COLOR_KEYS, "chroma_location"):
            value = source.get(key)
            if (
                value
                and value not in {"unknown", "unspecified"}
                and result.get(key) != value
            ):
                raise MediaError(f"Output verification detected changed {key}")
        for key in ("static_hdr_metadata", "dynamic_hdr_metadata_types"):
            if source.get(key) and source.get(key) != result.get(key):
                raise MediaError("Output verification detected changed HDR metadata")
        rate = _optional_finite_float(source.get("fps"), default=25.0)
        tolerance = max(0.12, 2 / max(1.0, rate))
        if abs(float(source["duration"]) - float(result["duration"])) > tolerance:
            raise MediaError("Output verification detected a duration change")
        constant_rate = source.get("average_frame_rate") == source.get(
            "nominal_frame_rate"
        )
        if (
            constant_rate
            and source.get("fps")
            and result.get("fps")
            and not math.isclose(
                float(source["fps"]),
                float(result["fps"]),
                rel_tol=0.001,
                abs_tol=0.01,
            )
        ):
            raise MediaError("Output verification detected a frame rate change")
        if (
            source.get("video_frame_count")
            and result.get("video_frame_count")
            and (source["video_frame_count"] != result["video_frame_count"])
        ):
            raise MediaError("Output verification detected a video frame count change")
        converted = self._inventory(temporary_path, job.cancel_event)
        before_tracks = self._tracks(original)
        after_tracks = self._tracks(
            converted,
            allow_generated_chapter_track=bool(original.get("chapters")),
        )
        if len(before_tracks) != len(after_tracks):
            raise MediaError(
                "Output verification detected a missing or unexpected track"
            )
        for before, after in zip(before_tracks, after_tracks, strict=True):
            kind = before.get("codec_type")
            expected = expected_codec if kind == "video" else before.get("codec_name")
            if after.get("codec_type") != kind or after.get("codec_name") != expected:
                raise MediaError(
                    "Output verification detected an unexpected track codec"
                )
            for key in ("channels", "sample_rate", "channel_layout", "bits_per_sample"):
                if (
                    kind == "audio"
                    and before.get(key)
                    and before.get(key) != after.get(key)
                ):
                    raise MediaError(
                        f"Output verification detected changed audio {key}"
                    )
            for key in ("language", "title", "filename", "mimetype"):
                value = (before.get("tags") or {}).get(key)
                # Some muxers write unspecified language as 'und' or omit it.
                if (
                    value
                    and value != "und"
                    and value != (after.get("tags") or {}).get(key)
                ):
                    raise MediaError(
                        f"Output verification detected changed track {key}"
                    )
            for key, enabled in (before.get("disposition") or {}).items():
                if enabled and not (after.get("disposition") or {}).get(key):
                    raise MediaError(
                        f"Output verification detected lost {key} track disposition"
                    )
            if kind == "attachment" and before.get("extradata_hash") != after.get(
                "extradata_hash"
            ):
                raise MediaError(
                    "Output verification detected changed attachment contents"
                )
            if kind in {"audio", "video"}:
                start_before = _optional_finite_float(before.get("start_time"))
                start_after = _optional_finite_float(after.get("start_time"))
                if abs(start_before - start_after) > tolerance:
                    raise MediaError(
                        "Output verification detected an audio/video timeline shift"
                    )
        old_chapters = original.get("chapters") or []
        new_chapters = converted.get("chapters") or []
        if len(old_chapters) != len(new_chapters):
            raise MediaError("Output verification detected missing chapters")
        for before, after in zip(old_chapters, new_chapters, strict=True):
            for key in ("start_time", "end_time"):
                if abs(float(before[key]) - float(after[key])) > 0.003:
                    raise MediaError(
                        "Output verification detected changed chapter timing"
                    )
            if (before.get("tags") or {}).get("title") != (after.get("tags") or {}).get(
                "title"
            ):
                raise MediaError("Output verification detected changed chapter titles")

    def _run_conversion(self, job: ConversionJob) -> None:
        temporary_path: Path | None = None
        published_path: Path | None = None
        process: subprocess.Popen[str] | None = None
        errors: deque[str] = deque(maxlen=40)
        try:
            with job.lock:
                if job.cancel_event.is_set():
                    raise InterruptedError
                job.status = "running"
                job.started_at = time.time()
                job.message = (
                    "Inspecting every video, audio, subtitle, and attachment track"
                )
            identity = self._identity(job.source.path)
            metadata = probe_video(
                job.source.path,
                ffprobe=self.ffprobe,
                cancel_event=job.cancel_event,
            )
            job.source = VideoSource(job.source.id, job.source.path, metadata)
            inventory = self._inventory(job.source.path, job.cancel_event)
            self._validate_tracks(job, inventory)
            minimum_space = (
                identity[2] * (1.1 if job.mode == "copy" else 2) + 64 * 1024 * 1024
            )
            if shutil.disk_usage(job.output_path.parent).free < minimum_space:
                raise MediaError(
                    "There is not enough free space in the output directory"
                )
            if job.mode != "copy" or metadata.get("is_hdr"):
                with job.lock:
                    job.message = "Inspecting frame color metadata before conversion"
                self._scan_all_frame_hdr_metadata(job)
            with job.lock:
                if job.cancel_event.is_set():
                    raise InterruptedError
                job.progress = max(5.0, job.progress)
                job.message = (
                    "Copying all compatible tracks without re-encoding"
                    if job.mode == "copy"
                    else "Encoding high-quality video; audio and subtitles remain unchanged"
                )
            descriptor, name = tempfile.mkstemp(
                prefix=f".conversion-{job.id}-",
                suffix=f".{job.target_format}",
                dir=job.output_path.parent,
            )
            os.close(descriptor)
            temporary_path = Path(name)
            command = self._command(job, temporary_path, inventory)
            with job.lock:
                if job.cancel_event.is_set():
                    raise InterruptedError
                process = subprocess.Popen(
                    command,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    bufsize=1,
                )
                job.process = process
                job.encoding_started_at = time.time()
            assert process.stdout is not None and process.stderr is not None

            def drain_stderr() -> None:
                assert process is not None and process.stderr is not None
                for line in process.stderr:
                    if line.strip():
                        errors.append(line.strip())

            stderr_thread = threading.Thread(target=drain_stderr, daemon=True)
            stderr_thread.start()
            duration = max(0.001, float(metadata["duration"]))
            expected_frames = float(metadata.get("video_frame_count") or 0)
            for line in process.stdout:
                if job.cancel_event.is_set() and process.poll() is None:
                    self._request_process_stop(process)
                key, separator, value = line.strip().partition("=")
                if separator and key in {"out_time_us", "out_time_ms"}:
                    seconds = _optional_finite_float(value, default=-1) / 1_000_000
                    if seconds >= 0:
                        with job.lock:
                            job.progress = min(
                                99.0, max(job.progress, 5 + seconds / duration * 94)
                            )
                elif separator and key == "frame" and expected_frames > 0:
                    frames = _optional_finite_float(value, default=-1)
                    if frames >= 0:
                        with job.lock:
                            job.progress = min(
                                99.0,
                                max(job.progress, 5 + frames / expected_frames * 94),
                            )
            return_code = process.wait()
            stderr_thread.join(timeout=2)
            with job.lock:
                job.process = None
            if job.cancel_event.is_set():
                raise InterruptedError
            if return_code != 0:
                detail = (
                    " | ".join(list(errors)[-3:])
                    or f"FFmpeg exited with code {return_code}"
                )
                raise MediaError(f"Conversion failed: {detail}")
            with job.lock:
                job.progress = 99.0
                job.message = "Verifying every track, picture geometry, color, timing, and chapters"
            self._verify_conversion(job, temporary_path, inventory)
            if self._identity(job.source.path) != identity:
                raise MediaError("The original video changed during conversion")
            with job.lock:
                if job.cancel_event.is_set():
                    raise InterruptedError
                published_path = self._publish(temporary_path, job.output_path)
                job.output_path = published_path
                job.status = "completed"
                job.progress = 100.0
                job.message = (
                    "Conversion completed; the original video was not modified"
                )
                job.finished_at = time.time()
                published_path = None
        except InterruptedError:
            with job.lock:
                job.status = "cancelled"
                job.message = (
                    "Conversion cancelled; the original video was not modified"
                )
                job.finished_at = time.time()
        except Exception as exc:  # noqa: BLE001 - worker failures must be reported
            with job.lock:
                job.status = "failed"
                job.error = str(exc) or exc.__class__.__name__
                job.message = "Conversion failed; the original video was not modified"
                job.finished_at = time.time()
        finally:
            if process is not None and process.poll() is None:
                self._escalate_process_stop(process)
            if process is not None:
                for pipe in (process.stdout, process.stderr):
                    if pipe is not None:
                        with contextlib.suppress(OSError):
                            pipe.close()
            cleanup_errors = [
                error
                for error in (
                    _remove_owned_file(temporary_path),
                    _remove_owned_file(published_path),
                )
                if error
            ]
            with job.lock:
                job.process = None
                if cleanup_errors:
                    job.status = "failed"
                    job.error = "; ".join(filter(None, [job.error, *cleanup_errors]))
                    job.message = "Conversion could not clean its partial output"
                    job.finished_at = time.time()
