"""Test real restricted audio decoding using synthetic media, never personal files."""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tools/SubtitleToolsHelper"))
sys.path.insert(0, str(ROOT / "Tools/DownloaderHelper"))

from subtitle_worker.common import PipelineError
from subtitle_worker.media import extract_audio, probe
from subtitle_worker.summary import SummaryProgress
from summary_source import Cancellation, SourceError, validate_audio


def run(ffmpeg: Path, ffprobe: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="chengying-summary-audio-") as name:
        root = Path(name).resolve()
        events = []
        for filename, codec in (("tone.m4a", "aac"), ("tone.flac", "flac")):
            media = root / filename
            subprocess.run([str(ffmpeg), "-hide_banner", "-loglevel", "error", "-nostdin", "-n",
                            "-f", "lavfi", "-i", "sine=frequency=440:duration=0.4", "-c:a", codec,
                            str(media)], stdin=subprocess.DEVNULL, check=True, timeout=20)
            validate_audio(media, ffprobe, 0.4, Cancellation())
            info = probe(media, str(ffprobe), require_video=False, restricted=True)
            output = root / f"{media.stem}-{codec}-speech.wav"
            extract_audio(media, output, info, str(ffmpeg), SummaryProgress(events.append),
                          lambda: False, restricted=True)
            speech = probe(output, str(ffprobe), require_video=False, restricted=True)
            assert speech["selected_audio"]["sample_rate"] == "16000"
            assert speech["selected_audio"]["channels"] == 1
            assert 0.3 < speech["duration"] < 0.6
        assert any(event.get("progress", 0) > 0 for event in events), "No measured FFmpeg progress"
        # Disguised playlists must not gain access to arbitrary external inputs.
        # The reference itself is another fixture, never a protected user file.
        disguised = root / "playlist.m4a"
        disguised.write_text("ffconcat version 1.0\nfile 'tone.flac'\n", encoding="utf-8")
        for check in (lambda: validate_audio(disguised, ffprobe, 0.4, Cancellation()),
                      lambda: probe(disguised, str(ffprobe), require_video=False, restricted=True)):
            try:
                check()
            except (SourceError, PipelineError):
                pass
            else:
                raise AssertionError("A disguised reference playlist was accepted as inert audio")
    print("Summary audio smoke passed: real AAC/FLAC decoding, mono 16 kHz analysis, progress, playlist rejection")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", required=True, type=Path)
    parser.add_argument("--ffprobe", required=True, type=Path)
    arguments = parser.parse_args()
    run(arguments.ffmpeg.resolve(strict=True), arguments.ffprobe.resolve(strict=True))


if __name__ == "__main__":
    main()
