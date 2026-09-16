from __future__ import annotations

import math
import re
from dataclasses import dataclass
from pathlib import Path

from .common import PipelineError, Segment

CJK = re.compile(r"[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]")
SENTENCE_END = re.compile(r"[。！？!?…]$|[.!?][\"'”’)]?$")


@dataclass
class TokenSpan:
    text: str
    start: float
    end: float


def clean_text(text: str) -> str:
    text = re.sub(r"<\|[^|>]+\|>", "", text or "")
    text = re.sub(r"\s+", " ", text).strip()
    text = re.sub(r"\s+([，。！？；：、,.!?;:）】》”’])", r"\1", text)
    return re.sub(r"([（【《“‘])\s+", r"\1", text)


def smart_join(parts, language="") -> str:
    result = ""
    korean = language.lower() in {"ko", "korean"}
    for raw in parts:
        token = raw.strip()
        if not token:
            continue
        space = bool(result) and token[0] not in "，。！？；：、,.!?;:）】》”’" and result[-1] not in "（【《“‘'’-"
        if space and not korean:
            space = not (CJK.search(result[-1]) or CJK.search(token[0]))
        result += (" " if space else "") + token
    return clean_text(result)


def restore_alignment_texts(transcript: str, tokens: list[str]) -> list[str]:
    """Restore punctuation omitted by the aligner's word tokenization."""
    restored = list(tokens)
    cursor, previous = 0, None
    for index, token in enumerate(tokens):
        if not token:
            continue
        candidates = [re.search(re.escape(token), transcript[cursor:], re.IGNORECASE)]
        if len(token) > 1:
            pattern = r"[^\w\s]*".join(re.escape(char) for char in token)
            candidates.append(re.search(pattern, transcript[cursor:], re.IGNORECASE))
        match = min((m for m in candidates if m), key=lambda m: m.start(), default=None)
        if not match:
            continue
        start, end = cursor + match.start(), cursor + match.end()
        restored[index] = transcript[start:end]
        gap = transcript[cursor:start]
        if gap and not any(char.isalnum() for char in gap):
            if previous is None:
                restored[index] = gap + restored[index]
            else:
                restored[previous] += gap
        cursor, previous = end, index
    trailing = transcript[cursor:]
    if trailing and previous is not None and not any(char.isalnum() for char in trailing):
        restored[previous] += trailing
    source_words = "".join(char for char in transcript if char.isalnum()).casefold()
    aligned_words = "".join(char for token in restored for char in token if char.isalnum()).casefold()
    if source_words != aligned_words:
        raise PipelineError("The aligner omitted or changed recognized words; refusing to save incomplete subtitles")
    return restored


def aligned_segments(items: list[dict], transcript: str, offset: float,
                     duration: float, language: str) -> list[Segment]:
    texts = restore_alignment_texts(transcript, [str(item.get("text", "")) for item in items])
    spans, pending = [], []
    previous = 0.0
    for item, text in zip(items, texts, strict=True):
        try:
            start, end = float(item["start_time"]), float(item["end_time"])
        except (KeyError, TypeError, ValueError) as exc:
            raise PipelineError("The aligner returned invalid timestamps") from exc
        if not math.isfinite(start) or not math.isfinite(end) or end < start:
            raise PipelineError("The aligner returned non-finite or reversed timestamps")
        start, end = max(0.0, start, previous), min(duration, end)
        text = clean_text(text)
        if text and end > start:
            spans.append(TokenSpan(smart_join([*pending, text], language), offset + start, offset + end))
            pending.clear()
        elif text and spans:
            # Timestamp quantization and overlapping word predictions must never
            # delete recognized words. Share the previous valid caption span.
            spans[-1].text = smart_join([spans[-1].text, text], language)
        elif text:
            # Leading zero-duration words inherit the first usable word span.
            pending.append(text)
        previous = max(previous, end)
    if transcript and not spans:
        raise PipelineError("The aligner did not produce usable word timestamps")
    groups, current = [], []
    for span in spans:
        if current and (span.end - current[0].start > 6
                        or span.start - current[-1].end > 0.75
                        or len(smart_join([s.text for s in current] + [span.text], language)) > 34
                        or (SENTENCE_END.search(current[-1].text)
                            and current[-1].end - current[0].start >= 1)):
            groups.append(current)
            current = []
        current.append(span)
    if current:
        groups.append(current)
    return [Segment(group[0].start, group[-1].end,
                    smart_join([s.text for s in group], language), language=language) for group in groups]


def normalize_segments(segments: list[Segment], duration: float) -> list[Segment]:
    result, previous_end = [], 0.0
    for item in sorted(segments, key=lambda s: (s.start, s.end)):
        if not math.isfinite(item.start) or not math.isfinite(item.end) or item.end < item.start:
            raise PipelineError("Subtitle timestamps are invalid")
        start, end = max(0.0, previous_end, item.start), min(duration, item.end)
        source, text = clean_text(item.source_text), clean_text(item.text)
        if (source or text) and end <= start:
            raise PipelineError("A non-empty subtitle has no usable time range within the video; refusing to discard its text")
        if end > start and (source or text):
            result.append(Segment(start, end, source, text or source, item.language))
            previous_end = end
    if not result:
        raise PipelineError("No speech with valid timestamps was detected")
    return result


def _timestamp(value: float, ass: bool = False) -> str:
    scale = 100 if ass else 1000
    ticks = max(0, round(value * scale))
    seconds, fraction = divmod(ticks, scale)
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if ass:
        return f"{hours}:{minutes:02}:{seconds:02}.{fraction:02}"
    return f"{hours:02}:{minutes:02}:{seconds:02},{fraction:03}"


def write_srt(path: Path, segments: list[Segment]) -> None:
    path.write_text("\n\n".join(f"{i}\n{_timestamp(s.start)} --> {_timestamp(s.end)}\n{s.text}"
                              for i, s in enumerate(segments, 1)) + "\n", encoding="utf-8")


def _ass_text(text: str) -> str:
    # Neutralize ASS override syntax while retaining readable literal text.
    return text.replace("\\", "＼").replace("{", "｛").replace("}", "｝").replace("\n", r"\N")


def write_ass(path: Path, segments: list[Segment]) -> None:
    header = """[Script Info]
Title: ChengYing Chinese Subtitles
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
WrapStyle: 0
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,PingFang SC,58,&H00FFFFFF,&H000000FF,&H00101010,&H80000000,0,0,0,0,100,100,0,0,1,3,1,2,100,100,64,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
    events = [f"Dialogue: 0,{_timestamp(s.start, True)},{_timestamp(s.end, True)},Default,,0,0,0,,{_ass_text(s.text)}"
              for s in segments]
    path.write_text(header + "\n".join(events) + "\n", encoding="utf-8")
