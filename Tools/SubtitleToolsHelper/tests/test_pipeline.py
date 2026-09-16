"""Offline worker tests: no model downloads and no accelerator required."""
from __future__ import annotations

import contextlib
import errno
import gc
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
import weakref
from pathlib import Path
from unittest import mock

HELPER = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HELPER))
from subtitle_worker import asr, common, media, pipeline, subtitles, translator
from subtitle_worker.common import Cancelled, PipelineError, Progress, Segment


class Tensor:
    device = "mps"

    def __init__(self, length=3, rank=2):
        self.length, self.rank = length, rank
        self.shape = (1, length) if rank == 2 else (length,)

    def __getitem__(self, item):
        if isinstance(item, tuple):
            return Tensor(self.length - (item[1].start or 0))
        if isinstance(item, slice):
            return Tensor(self.length - (item.start or 0), 1)
        return Tensor(self.length, 1)


class Batch(dict):
    def __init__(self):
        super().__init__(input_ids=Tensor())

    def to(self, *args):
        return self


def fake_torch():
    return types.SimpleNamespace(
        bfloat16="bfloat16", bool="bool", inference_mode=contextlib.nullcontext,
        backends=types.SimpleNamespace(mps=types.SimpleNamespace(is_available=lambda: True)),
        mps=types.SimpleNamespace(empty_cache=mock.Mock()), full=lambda *a, **kw: False)


class FakeModel:
    device, dtype = "mps", "bfloat16"
    config = types.SimpleNamespace(timestamp_token_id=42)

    def eval(self):
        return self

    def generate(self, **kwargs):
        return Tensor(7)

    def __call__(self, **kwargs):
        return types.SimpleNamespace(logits="logits")


class FakeProcessor:
    def apply_transcription_request(self, **kwargs):
        return Batch()

    def decode(self, *args, **kwargs):
        return [{"transcription": "Hello world!", "language": "English"}]

    def prepare_forced_aligner_inputs(self, **kwargs):
        return Batch(), [["Hello", "world"]]

    def decode_forced_alignment(self, **kwargs):
        return [[{"text": "Hello", "start_time": 0.1, "end_time": 0.6},
                 {"text": "world", "start_time": 0.7, "end_time": 1.2}]]


class FakeAudio:
    samplerate, channels = 16000, 1

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def __len__(self):
        return 32000

    def seek(self, position):
        pass

    def read(self, frames, **kwargs):
        return [0.0] * frames


class PipelineUnitTests(unittest.TestCase):
    def test_alignment_restores_punctuation_and_bounds(self):
        segments = subtitles.aligned_segments(
            [{"text": "Hello", "start_time": 0.0, "end_time": 0.5},
             {"text": "world", "start_time": 0.6, "end_time": 2.5}],
            "Hello, world!", 10, 2, "English")
        self.assertEqual(segments[0].source_text, "Hello, world!")
        self.assertEqual((segments[0].start, segments[0].end), (10, 12))

    def test_alignment_rejects_invalid_times(self):
        for start, end in ((float("nan"), 1), (0, float("inf")), (2, 1)):
            with self.subTest(start=start, end=end), self.assertRaises(PipelineError):
                subtitles.aligned_segments([{"text": "Hello", "start_time": start, "end_time": end}],
                                           "Hello", 0, 3, "English")

    def test_alignment_preserves_zero_duration_and_overlapping_words(self):
        cases = [
            ([('你', 0, .1), ('好', .1, .1), ('呀', .1, .2)], "你好呀", "Chinese"),
            ([('你', 0, 0), ('好', .1, .2)], "你好", "Chinese"),
            ([('你', 0, .1), ('好', .1, .1)], "你好", "Chinese"),
            ([("first", 0, 1), ("second", .5, .8), ("third", 1, 2)], "first second third", "English"),
        ]
        for words, transcript, language in cases:
            with self.subTest(transcript=transcript, words=words):
                items = [{"text": text, "start_time": start, "end_time": end} for text, start, end in words]
                segments = subtitles.aligned_segments(items, transcript, 0, 3, language)
                self.assertEqual(subtitles.smart_join([s.source_text for s in segments], language), transcript)
                self.assertTrue(all(0 <= segment.start < segment.end <= 3 for segment in segments))
        with self.assertRaises(PipelineError):
            subtitles.aligned_segments([{"text": "你", "start_time": 0, "end_time": 0}], "你", 0, 1, "Chinese")

    def test_normalization_never_extends_past_video_or_overlaps(self):
        result = subtitles.normalize_segments([Segment(0, 2, "A"), Segment(1, 9, "B")], 3)
        self.assertEqual([(s.start, s.end) for s in result], [(0, 2), (2, 3)])

    def test_normalization_rejects_text_that_would_be_lost(self):
        cases = [[Segment(0, 2, "First"), Segment(1, 1.5, "Second")],
                 [Segment(0, 0, "Word")], [Segment(4, 5, "Past the end")]]
        for segments in cases:
            with self.subTest(segments=segments), self.assertRaisesRegex(PipelineError, "refusing to discard"):
                subtitles.normalize_segments(segments, 3)

    def test_punctuation_restoration_rejects_missing_or_changed_words(self):
        for transcript, tokens in [("Hello brave world!", ["Hello", "world"]),
                                   ("Hello world!", ["Goodbye", "world"]),
                                   ("Hello world again", ["Hello", "world"])]:
            with self.subTest(transcript=transcript), self.assertRaisesRegex(PipelineError, "omitted or changed"):
                subtitles.restore_alignment_texts(transcript, tokens)

    def test_language_support_is_explicit(self):
        self.assertEqual(asr.normalize_language("zh-CN"), "Chinese")
        with self.assertRaisesRegex(PipelineError, "does not support"):
            asr.normalize_language("Arabic")

    def test_progress_monotonic_and_eta_scoped(self):
        events = []
        progress = Progress(events.append)
        progress.report("recognizing", .4, "A")
        progress.report("recognizing", .2, "B", 10)
        self.assertEqual(events[-1]["progress"], .4)
        self.assertEqual(events[-1]["eta_scope"], "stage")
        with self.assertRaises(ValueError):
            progress.report("bad", float("nan"), "Bad")

    def test_memory_refuses_translation_without_substitution(self):
        with mock.patch.object(common, "physical_memory_bytes", return_value=64 * 1024**3), \
                self.assertRaisesRegex(PipelineError, "96 GiB"):
            common.require_translation_memory()

    def test_mandarin_never_loads_translation_model(self):
        converter = types.SimpleNamespace(OpenCC=lambda _: types.SimpleNamespace(convert=lambda text: text))
        with mock.patch.dict(sys.modules, {"opencc": converter, "torch": None, "transformers": None}):
            result = translator.translate([Segment(0, 1, "Chinese text", language="Chinese")],
                                          {}, Progress(lambda event: None), lambda: False)
        self.assertEqual(result[0].text, "Chinese text")

    def test_marker_parser_rejects_missing_duplicate_and_reordered_segments(self):
        self.assertEqual(translator.parse_batch("<<<SUB_100000>>>One", [100000]), {100000: "One"})
        for text in ("<<<SUB_1>>>One", "<<<SUB_1>>>One<<<SUB_1>>>Two",
                     "<<<SUB_2>>>Two<<<SUB_1>>>One", "<<<SUB_1>>><<<SUB_2>>>Two"):
            self.assertIsNone(translator.parse_batch(text, [1, 2]))

    def test_publication_never_overwrites_and_cleans_partial_collision(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "movie.mp4"
            source.touch()
            temp = root / "work"
            temp.mkdir()
            for extension in ("srt", "ass"):
                (temp / f"subtitles.{extension}").write_text("new")
            old = root / "movie.zh-CN.ass"
            old.write_text("old")
            outputs = pipeline.publish_sidecars(source, temp)
            self.assertEqual(old.read_text(), "old")
            self.assertFalse((root / "movie.zh-CN.srt").exists())
            self.assertTrue(outputs["ass"].endswith("movie.zh-CN.2.ass"))

    def test_publication_on_volumes_without_hard_links(self):
        with tempfile.TemporaryDirectory() as directory:
            source, destination = Path(directory) / "source", Path(directory) / "destination"
            source.write_text("preserved")
            with mock.patch.object(pipeline.os, "link", side_effect=OSError(errno.EOPNOTSUPP, "No hard links")):
                pipeline.publish_exclusive(source, destination)
                with self.assertRaises(FileExistsError):
                    pipeline.publish_exclusive(source, destination)
            self.assertEqual(destination.read_text(), "preserved")

    def test_native_asr_offline_flags_and_stage_unloading(self):
        loads, references = [], []

        def load_model(path, **kwargs):
            gc.collect()
            if references:
                self.assertIsNone(references[-1](), "The previous stage retained its model")
            model = FakeModel()
            references.append(weakref.ref(model))
            loads.append((path, kwargs))
            return model

        processor_loads = []

        def load_processor(path, **kwargs):
            processor_loads.append(kwargs)
            return FakeProcessor()

        factory = types.SimpleNamespace(from_pretrained=load_model)
        transformers = types.SimpleNamespace(
            AutoProcessor=types.SimpleNamespace(from_pretrained=load_processor),
            AutoModelForMultimodalLM=factory, AutoModelForTokenClassification=factory,
            StoppingCriteria=object, StoppingCriteriaList=list)
        with tempfile.TemporaryDirectory() as directory:
            paths = {}
            for name in ("asr", "aligner"):
                path = Path(directory) / name
                path.mkdir()
                (path / "config.json").write_text("{}")
                paths[name] = str(path)
            with mock.patch.dict(sys.modules, {"torch": fake_torch(), "transformers": transformers,
                                               "soundfile": types.SimpleNamespace(SoundFile=lambda _: FakeAudio())}), \
                    mock.patch.object(asr, "plan_chunks", return_value=[asr.Chunk(0, 32000)]):
                result = asr.transcribe(Path("unused.wav"), paths, "auto", Progress(lambda _: None), lambda: False)
        self.assertEqual(result[0].source_text, "Hello world!")
        self.assertEqual(len(loads), 2)
        for _, options in loads:
            self.assertEqual(options["dtype"], "bfloat16")
            self.assertEqual(options["device_map"], {"": "mps"})
            self.assertTrue(options["local_files_only"])
            self.assertTrue(options["use_safetensors"])
            self.assertFalse(options["trust_remote_code"])
        self.assertTrue(all(options == {"local_files_only": True, "trust_remote_code": False}
                            for options in processor_loads))

    def test_translation_uses_full_local_model_and_same_model_format_retry(self):
        calls, generation = [], []
        answers = iter(["Invalid batch formatting", "First translation", "Second translation"])

        class Tokenizer:
            def apply_chat_template(self, *args, **kwargs):
                return Batch()

            def decode(self, *args, **kwargs):
                return next(answers)

        class Model(FakeModel):
            def generate(self, **kwargs):
                generation.append(kwargs)
                return Tensor(7)

        def load_model(path, **options):
            calls.append(options)
            return Model()

        transformers = types.SimpleNamespace(
            AutoTokenizer=types.SimpleNamespace(from_pretrained=lambda *args, **kwargs: Tokenizer()),
            AutoModelForCausalLM=types.SimpleNamespace(from_pretrained=load_model),
            StoppingCriteria=object, StoppingCriteriaList=list)
        converter = types.SimpleNamespace(OpenCC=lambda _: types.SimpleNamespace(convert=lambda text: text))
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "config.json").write_text("{}")
            with mock.patch.dict(sys.modules, {"torch": fake_torch(), "transformers": transformers, "opencc": converter}), \
                    mock.patch.object(translator, "require_translation_memory"):
                result = translator.translate([Segment(0, 1, "Hello", language="English"),
                                               Segment(1, 2, "World", language="English")],
                                              {"translator": directory}, Progress(lambda _: None), lambda: False)
        self.assertEqual([s.text for s in result], ["First translation", "Second translation"])
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(generation), 3)
        self.assertEqual(calls[0]["dtype"], "bfloat16")
        self.assertTrue(calls[0]["local_files_only"])
        self.assertFalse(calls[0]["trust_remote_code"])
        for options in generation:
            self.assertEqual((options["temperature"], options["top_p"], options["top_k"]), (.7, 1., 0))

    def test_worker_failure_stdout_is_jsonl_only(self):
        with tempfile.TemporaryDirectory() as directory:
            request = Path(directory) / "request.json"
            request.write_text(json.dumps({"id": "test-worker"}))
            process = subprocess.run([sys.executable, "-I", str(HELPER / "subtitle_worker" / "worker.py"),
                                      "--request-json", str(request)], capture_output=True, text=True, timeout=15, check=False)
        self.assertEqual(process.returncode, 1)
        events = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual(events[-1]["type"], "failed")
        self.assertEqual(events[-1]["id"], "test-worker")
        self.assertIn("Traceback", process.stderr)

    def test_burn_rejects_unsafe_color_rotation_and_interlace(self):
        for extra in ({"color_transfer": "smpte2084"}, {"color_primaries": "bt2020"},
                      {"pix_fmt": "rgb24"}, {"field_order": "tt"}, {"tags": {"rotate": "90"}},
                      {"side_data_list": [{"side_data_type": "DOVI configuration record"}]}):
            with self.subTest(extra=extra), self.assertRaises(PipelineError):
                media.validate_burn_source({"video": {"pix_fmt": "yuv420p", **extra}})


class FFmpegPipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        candidates = [os.environ.get("SUBTITLE_TEST_FFMPEG"), "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg",
                      shutil.which("ffmpeg")]
        cls.ffmpeg = next((value for value in candidates if value and Path(value).is_file()), None)
        cls.ffprobe = str(Path(cls.ffmpeg).with_name("ffprobe")) if cls.ffmpeg else None
        if not cls.ffmpeg or not Path(cls.ffprobe).is_file():
            raise unittest.SkipTest("FFmpeg / FFprobe are unavailable")
        filters = subprocess.run([cls.ffmpeg, "-hide_banner", "-filters"], capture_output=True, text=True, timeout=10, check=False)
        if " ass " not in filters.stdout:
            raise unittest.SkipTest("FFmpeg was built without libass")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chengying-pipeline-test-")
        self.root = Path(self.temporary.name)
        self.source = self.root / "input video.mp4"
        result = subprocess.run([self.ffmpeg, "-hide_banner", "-loglevel", "error", "-n",
                                 "-f", "lavfi", "-i", "color=c=blue:s=320x180:r=30:d=2",
                                 "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                                 "-c:v", "libx264", "-pix_fmt", "yuv420p", "-colorspace", "bt709",
                                 "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv",
                                 "-c:a", "aac", "-shortest", str(self.source)],
                                capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.request = {"input_path": str(self.source), "data_dir": str(self.root / "models"),
                        "ffmpeg": self.ffmpeg, "ffprobe": self.ffprobe, "language": "zh"}

    def tearDown(self):
        self.temporary.cleanup()

    def run_fake_models(self, burn=False):
        self.request["burn_subtitles"] = burn
        events = []
        with mock.patch.object(pipeline, "transcribe", return_value=[Segment(.1, 1.8, "Test subtitle", "Test subtitle", "Chinese")]), \
                mock.patch.object(pipeline, "translate", side_effect=lambda segments, *args: segments):
            result = pipeline.run_pipeline(self.request, events.append)
        self.assertFalse(list(self.root.glob(".chengying-subtitles-*")))
        self.assertEqual([e["progress"] for e in events], sorted(e["progress"] for e in events))
        return result

    def test_external_subtitles_leave_original_untouched(self):
        original = self.source.read_bytes()
        result = self.run_fake_models()
        self.assertFalse(result["partial"])
        self.assertEqual(set(result["outputs"]), {"srt", "ass"})
        self.assertEqual(self.source.read_bytes(), original)
        self.assertIn("00:00:00,100 --> 00:00:01,800", Path(result["outputs"]["srt"]).read_text())

    def test_actual_lossless_burn_preserves_audio_and_geometry(self):
        result = self.run_fake_models(burn=True)
        self.assertFalse(result["partial"], result["warnings"])
        output = Path(result["outputs"]["video"])
        before, after = media.probe(self.source, self.ffprobe), media.probe(output, self.ffprobe)
        self.assertEqual(after["video"]["codec_name"], "ffv1")
        for field in ("width", "height", "pix_fmt", "color_space", "color_transfer", "color_primaries"):
            self.assertEqual(before["video"].get(field), after["video"].get(field))

        def audio_hash(path):
            output = subprocess.check_output([self.ffmpeg, "-v", "error", "-i", str(path),
                                              "-map", "0:a:0", "-c:a", "copy", "-f", "hash", "-hash", "sha256", "-"], timeout=15)
            return output.strip()
        self.assertEqual(audio_hash(self.source), audio_hash(output))

    def test_ten_bit_sdr_is_not_downgraded_to_eight_bit(self):
        ten_bit = self.root / "ten-bit.mkv"
        result = subprocess.run([self.ffmpeg, "-v", "error", "-n", "-i", str(self.source),
                                 "-c:v", "ffv1", "-pix_fmt", "yuv420p10le", "-c:a", "copy", str(ten_bit)],
                                capture_output=True, text=True, timeout=20, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.request["input_path"] = str(ten_bit)
        output = self.run_fake_models(burn=True)
        self.assertFalse(output["partial"], output["warnings"])
        info = media.probe(Path(output["outputs"]["video"]), self.ffprobe)
        self.assertEqual(info["video"]["pix_fmt"], "yuv420p10le")

    def test_burn_failure_preserves_completed_sidecars(self):
        with mock.patch.object(pipeline, "burn_subtitles", side_effect=PipelineError("HDR is unsupported")):
            result = self.run_fake_models(burn=True)
        self.assertTrue(result["partial"])
        self.assertNotIn("video", result["outputs"])
        self.assertTrue(all(Path(value).is_file() for value in result["outputs"].values()))

    def test_cancellation_removes_temporary_audio(self):
        with mock.patch.object(pipeline, "transcribe", side_effect=Cancelled("Cancelled")), self.assertRaises(Cancelled):
            pipeline.run_pipeline(self.request, lambda _: None)
        self.assertFalse(list(self.root.glob(".chengying-subtitles-*")))
        self.assertFalse(list(self.root.glob("*.srt")))


def run_native_smoke(data_directory: Path, ffmpeg: Path) -> None:
    """Opt-in real BF16/MPS integration test; download only ASR and aligner."""
    from concurrent.futures import ThreadPoolExecutor

    from downloads import Artifact, ArtifactStore

    data_directory = data_directory.expanduser().resolve()
    store = ArtifactStore(data_directory)
    manifest = json.loads((HELPER / "assets.json").read_text())
    artifacts = [Artifact.from_dict(artifact) for model in manifest["models"]
                 if model["id"] in {"asr", "aligner"} for artifact in model["artifacts"]]
    cancel, last_report, lock = threading.Event(), {}, threading.Lock()

    def report(artifact, stage, count, speed):
        now = time.monotonic()
        with lock:
            if count < artifact.size and now - last_report.get(artifact.id, 0) < 5:
                return
            last_report[artifact.id] = now
            print(json.dumps({"artifact": artifact.id, "stage": stage, "bytes": count,
                              "total": artifact.size, "bytes_per_second": speed}), flush=True)

    def prepare(artifact):
        for attempt in range(3):
            try:
                return store.ensure(artifact, cancel, report)
            except Exception:
                if attempt == 2:
                    raise
                time.sleep(1)

    with ThreadPoolExecutor(max_workers=2) as executor:
        list(executor.map(prepare, artifacts))
    print("Verified official ASR and aligner artifacts; starting synthetic-speech integration test", flush=True)
    with tempfile.TemporaryDirectory(prefix="speech-smoke-", dir=data_directory) as directory:
        temporary = Path(directory)
        speech, video = temporary / "speech.aiff", temporary / "synthetic.mp4"
        text = "你好，欢迎使用澄影播放器。现在我们正在测试自动中文字幕，画面和声音都保持原来的质量。"
        subprocess.run(["/usr/bin/say", "-v", "Tingting", "-r", "150", "-o", str(speech), text],
                       check=True, timeout=60)
        subprocess.run([str(ffmpeg), "-hide_banner", "-loglevel", "error", "-n", "-f", "lavfi", "-i",
                        "color=c=blue:s=640x360:r=30", "-i", str(speech), "-shortest", "-c:v", "libx264",
                        "-pix_fmt", "yuv420p", "-c:a", "alac", str(video)], check=True, timeout=60)
        request = {"id": "native-smoke", "input_path": str(video), "language": "zh",
                   "burn_subtitles": False, "data_dir": str(data_directory),
                   "ffmpeg": str(ffmpeg.resolve()), "ffprobe": str(ffmpeg.resolve().with_name("ffprobe"))}
        events = []

        def emit(event):
            events.append(event)
            print(json.dumps(event, ensure_ascii=False), flush=True)

        result = pipeline.run_pipeline(request, emit)
        print(json.dumps(result, ensure_ascii=False), flush=True)
        transcript = Path(result["outputs"]["srt"]).read_text(encoding="utf-8")
        print(transcript, flush=True)
        if not all(token in transcript for token in ("你好", "字幕", "声音", "质量")):
            raise AssertionError("The synthetic Chinese transcript did not retain its expected keywords")
        if result.get("partial") or {event["stage"] for event in events}.isdisjoint({"aligning"}):
            raise AssertionError("The native pipeline did not complete forced alignment")
        # Keep a small, reproducible report, never the temporary audio/video fixture.
        report_path = data_directory / "native-smoke-result.json"
        report_path.write_text(json.dumps({"events": events, "result": result, "srt": transcript},
                                          ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"Native smoke passed. Report: {report_path}", flush=True)


if __name__ == "__main__":
    if "--native-smoke" in sys.argv:
        import argparse
        parser = argparse.ArgumentParser()
        parser.add_argument("--native-smoke", type=Path, required=True)
        parser.add_argument("--ffmpeg", type=Path, required=True)
        arguments = parser.parse_args()
        run_native_smoke(arguments.native_smoke, arguments.ffmpeg)
    else:
        unittest.main()
