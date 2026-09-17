from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path

from .common import (
    PipelineError,
    cancellation_criteria,
    check_cancelled,
    local_options,
    model_options,
    model_path,
    release_memory,
    torch_device,
)
from .subtitles import aligned_segments, clean_text, normalize_segments

LANGUAGES = {"zh": "Chinese", "yue": "Cantonese", "en": "English", "ja": "Japanese",
             "ko": "Korean", "fr": "French", "de": "German", "it": "Italian",
             "pt": "Portuguese", "ru": "Russian", "es": "Spanish"}
ALIGNER_LANGUAGES = set(LANGUAGES.values())


@dataclass
class Chunk:
    first: int
    last: int
    text: str = ""
    language: str = ""


def normalize_language(value: str) -> str | None:
    if not value or value.lower() in {"auto", "unknown"}:
        return None
    if value.lower() in {"mandarin", "zh-cn", "zh-hans", "zh-hant"}:
        return "Chinese"
    for key, language in LANGUAGES.items():
        if value.lower() in {key, language.lower()}:
            return language
    raise PipelineError(f"Precise forced alignment does not support language: {value}. "
                        "Supported languages: " + ", ".join(LANGUAGES.values()))


def plan_chunks(audio, sample_rate: int, maximum_seconds: int = 60) -> list[Chunk]:
    """Bound memory independently of video length; choose low-energy boundaries."""
    import numpy as np
    total = len(audio)
    maximum = maximum_seconds * sample_rate
    position, chunks = 0, []
    while position < total:
        end = min(total, position + maximum)
        if end < total:
            search_start = max(position + maximum // 2, end - 3 * sample_rate)
            audio.seek(search_start)
            tail = audio.read(end - search_start, dtype="float32", always_2d=False)
            window = sample_rate // 10
            usable = len(tail) // window * window
            if usable:
                energy = np.mean(np.square(tail[:usable].reshape(-1, window)), axis=1)
                end = search_start + int(np.argmin(energy)) * window + window // 2
        chunks.append(Chunk(position, end))
        position = end
    return chunks


def _read_chunk(audio, chunk: Chunk):
    audio.seek(chunk.first)
    return audio.read(chunk.last - chunk.first, dtype="float32", always_2d=False)


def transcribe(audio_path: Path, paths: dict, language_hint: str, progress, cancelled):
    import soundfile as sf
    import torch
    import transformers

    language = normalize_language(language_hint)
    device = torch_device(torch)
    model = processor = inputs = output = None
    criteria = cancellation_criteria(torch, transformers, cancelled)
    with sf.SoundFile(str(audio_path)) as audio:
        if audio.samplerate != 16000 or audio.channels != 1:
            raise PipelineError("Internal audio must be mono 16000 Hz")
        sample_rate, duration = audio.samplerate, len(audio) / audio.samplerate
        chunks = plan_chunks(audio, sample_rate)
        if not chunks:
            raise PipelineError("The selected audio track is empty")
        try:
            check_cancelled(cancelled)
            progress.report("recognizing", 0.10, "Loading Qwen3-ASR-1.7B BF16 from local files")
            path = model_path(paths, "asr")
            processor = transformers.AutoProcessor.from_pretrained(str(path), **local_options())
            model = transformers.AutoModelForMultimodalLM.from_pretrained(str(path), **model_options(torch, device)).eval()
            started = time.monotonic()
            for index, chunk in enumerate(chunks, 1):
                check_cancelled(cancelled)
                streaming = {}
                if hasattr(progress, "token_streamer"):
                    progress.start_chunk("recognizing", index, len(chunks))
                    streaming["streamer"] = progress.token_streamer("recognizing")
                inputs = processor.apply_transcription_request(audio=_read_chunk(audio, chunk), language=language)
                inputs = inputs.to(model.device, model.dtype)
                with torch.inference_mode():
                    output = model.generate(**inputs, max_new_tokens=4096, do_sample=False,
                                            stopping_criteria=criteria, **streaming)
                check_cancelled(cancelled)
                generated = output[:, inputs["input_ids"].shape[1]:]
                if generated.shape[-1] >= 4096:
                    raise PipelineError("ASR reached its output limit; refusing to silently truncate subtitles")
                parsed = processor.decode(generated, return_format="parsed")[0]
                chunk.text = clean_text(str(parsed.get("transcription", "") or ""))
                if chunk.text:
                    chunk.language = normalize_language(str(parsed.get("language", "") or language or "")) or ""
                    if not chunk.language:
                        raise PipelineError("ASR could not identify the speech language for precise alignment")
                inputs = output = generated = None
                progress.chunks("recognizing", index, len(chunks), started, 0.10, 0.49)
        finally:
            model = processor = inputs = output = None
            release_memory(torch)

        voiced = [chunk for chunk in chunks if chunk.text]
        if not voiced:
            raise PipelineError("No speech was detected in the selected audio track")
        segments = []
        try:
            check_cancelled(cancelled)
            progress.report("aligning", 0.50, "Loading Qwen3-ForcedAligner-0.6B BF16 from local files")
            path = model_path(paths, "aligner")
            processor = transformers.AutoProcessor.from_pretrained(str(path), **local_options())
            model = transformers.AutoModelForTokenClassification.from_pretrained(str(path), **model_options(torch, device)).eval()
            started = time.monotonic()
            for index, chunk in enumerate(voiced, 1):
                check_cancelled(cancelled)
                inputs, word_lists = processor.prepare_forced_aligner_inputs(
                    audio=_read_chunk(audio, chunk), transcript=chunk.text, language=chunk.language)
                inputs = inputs.to(model.device, model.dtype)
                with torch.inference_mode():
                    output = model(**inputs)
                check_cancelled(cancelled)
                timestamps = processor.decode_forced_alignment(
                    logits=output.logits, input_ids=inputs["input_ids"], word_lists=word_lists,
                    timestamp_token_id=model.config.timestamp_token_id)[0]
                segments.extend(aligned_segments(timestamps, chunk.text, chunk.first / sample_rate,
                                                 (chunk.last - chunk.first) / sample_rate, chunk.language))
                inputs = output = None
                progress.chunks("aligning", index, len(voiced), started, 0.50, 0.68)
        finally:
            model = processor = inputs = output = None
            release_memory(torch)
    return normalize_segments(segments, duration)
