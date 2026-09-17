"""Offline summary regressions using small source files and deterministic models."""
from __future__ import annotations

import copy
import hashlib
import json
import sys
import tempfile
import threading
import types
import unittest
import uuid
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from downloads import Cancelled
from helper import Supervisor
from runtime import Runtime, run_process
from subtitle_worker import media, summary
from subtitle_worker.common import PipelineError, Segment
from test_helper import fixture_manifest
from test_pipeline import Batch, Tensor, fake_torch


class CharacterTokenizer:
    def apply_chat_template(self, values, **kwargs):
        value = json.dumps(values, ensure_ascii=False)
        return list(value) if kwargs.get("tokenize", True) else value


def source_fixture():
    return {"schema_version": 1, "title": "A source title", "source_url": "https://www.youtube.com/watch?v=abcdefghijk",
            "platform": "youtube", "video_id": "abcdefghijk", "duration": 60,
            "content_source": "subtitles", "segments": [{"start": 0, "end": 20, "source_text": "The first source fact."},
                                                         {"start": 20, "end": 60, "source_text": "The second source fact."}], "warnings": []}


def report_fixture(items, mode="map"):
    if mode == "map":
        citation = {"id": items[0]["id"], "quote": items[0]["source_text"][:30]}
    else:
        citation = dict(items[0]["claims"][0]["evidence"][0])
    claim = {"text": "A verified Chinese summary claim", "evidence": [citation]}
    return {"covered_ids": [item["id"] for item in items], "chapter_title": "Chapter", "overview": [claim], "key_points": [copy.deepcopy(claim)]}


class DeterministicSummarizer:
    tokenizer = CharacterTokenizer()
    def __init__(self, *args):
        self.calls, self.closed = [], False
    def generate(self, items, evidence, mode):
        self.calls.append((items, mode))
        return summary.validate_report(report_fixture(items, mode), items, evidence, mode)
    def close(self):
        self.closed = True


class SummaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chengying-summary-test-")
        self.root = Path(self.temporary.name).resolve()
        self.job = self.root / "summaries" / str(uuid.uuid4()).upper()
        self.job.mkdir(parents=True)
        self.source_path = self.job / "source.json"
        self.source_path.write_text(json.dumps(source_fixture()))
        self.model_path = self.root / "models" / "summarizer"
        self.model_path.mkdir(parents=True)
        (self.model_path / "config.json").write_text("{}")
        self.events = []

    def tearDown(self):
        self.temporary.cleanup()

    def request(self):
        return {"operation": "summary", "source_path": str(self.source_path), "output_dir": str(self.job),
                "data_dir": str(self.root), "model_paths": {"summarizer": str(self.model_path)}}

    def test_source_rejects_unknown_hosts_credentials_nonfinite_and_invalid_segments(self):
        for edit in ({"source_url": "https://evil.example/watch?v=x"}, {"source_url": "https://name@youtube.com/watch?v=x"},
                     {"duration": float("nan")}, {"segments": []},
                     {"segments": [{"start": 10, "end": 5, "source_text": "text"}]},
                     {"segments": [{"start": 0, "end": 70, "source_text": "text"}]},
                     {"segments": [{"start": True, "end": 3, "source_text": "text"}]}):
            with self.subTest(edit=edit):
                self.source_path.write_text(json.dumps({**source_fixture(), **edit}))
                with self.assertRaises(PipelineError):
                    summary.read_source(self.source_path, self.job)

    def test_source_rejects_symlink_and_outside_audio_paths(self):
        outside = self.root / "audio.m4a"
        outside.write_bytes(b"audio")
        source = {**source_fixture(), "content_source": "audio", "audio_path": str(outside)}
        self.source_path.write_text(json.dumps(source))
        with self.assertRaises(PipelineError):
            summary.read_source(self.source_path, self.job)
        linked = self.job / "audio.m4a"
        linked.symlink_to(outside)
        source["audio_path"] = str(linked)
        self.source_path.write_text(json.dumps(source))
        with self.assertRaises(PipelineError):
            summary.read_source(self.source_path, self.job)

    def test_long_unicode_transcript_is_split_without_truncation(self):
        original = "中文🙂text\n" * 2400
        segments = [{"id": "s000001", "start": 10.0, "end": 20.0, "source_text": original}]
        chunks, evidence = summary.chunk_segments(segments, CharacterTokenizer())
        self.assertGreater(len(chunks), 1)
        self.assertEqual("".join(row["source_text"] for chunk in chunks for row in chunk), original)
        self.assertEqual(len(evidence), sum(len(chunk) for chunk in chunks))
        for chunk in chunks:
            self.assertLessEqual(summary.prompt_tokens(CharacterTokenizer(), chunk, "map"), summary.INPUT_TOKEN_LIMIT)
            for row in chunk:
                self.assertEqual(evidence[row["id"]]["start"], 10)

    def test_map_and_reduce_cover_all_segments_and_preserve_chapters(self):
        segments = [{"id": f"s{index}", "start": index, "end": index + 1, "source_text": "source fact " * 120} for index in range(12)]
        fake = DeterministicSummarizer()
        final, chapters, evidence = summary.summarize_segments(segments, fake, summary.SummaryProgress(self.events.append), lambda: False)
        mapped = [row["id"] for rows, mode in fake.calls if mode == "map" for row in rows]
        self.assertEqual(mapped, [segment["id"] for segment in segments])
        self.assertEqual(len(chapters), sum(mode == "map" for _, mode in fake.calls))
        self.assertTrue(any(mode == "reduce" for _, mode in fake.calls))
        self.assertTrue(final["overview"])
        self.assertEqual(set(evidence), set(mapped))
        self.assertTrue(all(event.get("eta_scope", "stage") == "stage" for event in self.events))

    def test_reject_missing_coverage_fabricated_quote_and_cross_chunk_reference(self):
        rows = [{"id": "s1", "source_text": "The original text"}]
        evidence = {"s1": rows[0], "s2": {"source_text": "The original text"}}
        original = report_fixture(rows)
        cases = []
        changed = copy.deepcopy(original)
        changed["covered_ids"] = []
        cases.append(changed)
        changed = copy.deepcopy(original)
        changed["overview"][0]["evidence"][0]["quote"] = "Invented fact"
        cases.append(changed)
        changed = copy.deepcopy(original)
        changed["overview"][0]["evidence"][0]["id"] = "s2"
        cases.append(changed)
        for value in cases:
            with self.assertRaises(PipelineError):
                summary.validate_report(value, rows, evidence, "map")

    def test_reduce_cannot_introduce_new_evidence_even_if_in_original(self):
        source = {"id": "s1", "source_text": "A first fact and another fact"}
        claim = {"text": "First", "evidence": [{"id": "s1", "quote": "first fact"}]}
        rows = [{"id": "m1", "claims": [claim]}]
        report = report_fixture(rows, "reduce")
        report["overview"][0]["evidence"][0]["quote"] = "another fact"
        with self.assertRaises(PipelineError):
            summary.validate_report(report, rows, {"s1": source}, "reduce")

    def test_token_counter_skips_prompt_emits_real_counts_and_never_text(self):
        progress = summary.SummaryProgress(self.events.append)
        progress.start_chunk("summary_mapping", 1, 2)
        counter = progress.token_streamer("summary_mapping")
        counter.put(types.SimpleNamespace(numel=lambda: 1000))
        for _ in range(5):
            counter.put(types.SimpleNamespace(numel=lambda: 1))
        counter.end()
        self.assertEqual(self.events[-1]["tokens_generated"], 5)
        self.assertEqual(self.events[-1]["chunk_count"], 2)
        self.assertNotIn("progress", self.events[-1])
        self.assertNotIn("text", self.events[-1])
        self.assertNotIn("eta_seconds", self.events[-1])
        next_counter = progress.token_streamer("summary_mapping")
        next_counter.put(types.SimpleNamespace(numel=lambda: 1000))
        next_counter.put(types.SimpleNamespace(numel=lambda: 2))
        next_counter.end()
        self.assertEqual(self.events[-1]["tokens_generated"], 7)
        progress.send("summary_loading", "Loading model")
        self.assertEqual((self.events[-1]["chunk_index"], self.events[-1]["chunk_count"]), (0, 0))

    def test_subtitles_use_no_asr_and_publish_exclusively_in_private_directory(self):
        fake = DeterministicSummarizer()
        opencc = types.SimpleNamespace(OpenCC=lambda _: types.SimpleNamespace(convert=lambda value: value))
        with patch.object(summary, "physical_memory_bytes", return_value=128 * 1024**3), patch.object(summary, "LocalSummarizer", return_value=fake), patch.object(summary, "transcribe") as asr, patch.dict(sys.modules, {"opencc": opencc}):
            result = summary.run_summary(self.request(), self.events.append)
        asr.assert_not_called()
        self.assertTrue(fake.closed)
        self.assertEqual(result["outputs"], {"summary": str(self.job / "report.md"), "transcript": str(self.job / "transcript.json")})
        self.assertEqual((self.job / "report.md").read_text(), result["summary_text"])
        self.assertEqual((self.job / "report.md").stat().st_nlink, 1)
        self.assertEqual(len(json.loads((self.job / "transcript.json").read_text())["segments"]), 2)
        self.assertIn("watch?v=abcdefghijk&t=0", result["summary_text"])
        self.assertIn("没有分析视频画面", result["summary_text"])
        with patch.object(summary, "physical_memory_bytes", return_value=128 * 1024**3), patch.object(summary, "LocalSummarizer", return_value=DeterministicSummarizer()), patch.dict(sys.modules, {"opencc": opencc}), self.assertRaises(FileExistsError):
            summary.run_summary(self.request(), self.events.append)
        self.assertEqual((self.job / "report.md").read_text(), result["summary_text"])

    def test_audio_fallback_transcribes_before_loading_summarizer_without_translation(self):
        audio = self.job / "speech.m4a"
        audio.write_bytes(b"audio")
        self.source_path.write_text(json.dumps({**source_fixture(), "content_source": "audio", "audio_path": str(audio), "segments": []}))
        order = []
        fake = DeterministicSummarizer()
        def transcribe(*args):
            order.append("transcribe")
            return [Segment(0, 5, "Spoken original fact")]
        def load(*args):
            order.append("summarizer")
            return fake
        request = {**self.request(), "ffmpeg": "/bundled/ffmpeg", "ffprobe": "/bundled/ffprobe"}
        opencc = types.SimpleNamespace(OpenCC=lambda _: types.SimpleNamespace(convert=lambda value: value))
        with patch.object(summary, "physical_memory_bytes", return_value=128 * 1024**3), patch.object(summary, "probe", return_value={"duration": 5}) as probe, patch.object(summary, "extract_audio") as extract, patch.object(summary, "transcribe", side_effect=transcribe), patch.object(summary, "LocalSummarizer", side_effect=load), patch.dict(sys.modules, {"opencc": opencc}):
            result = summary.run_summary(request, self.events.append)
        self.assertEqual(order, ["transcribe", "summarizer"])
        self.assertFalse(probe.call_args.kwargs["require_video"])
        self.assertTrue(probe.call_args.kwargs["restricted"])
        self.assertTrue(extract.call_args.kwargs["restricted"])
        self.assertEqual(extract.call_args.args[0], audio)
        self.assertEqual(result["content_source"], "audio")
        self.assertEqual(json.loads((self.job / "transcript.json").read_text())["segments"][0]["source_text"], "Spoken original fact")

    def test_cancellation_between_publications_removes_only_this_jobs_partial_report(self):
        cancelled = threading.Event()
        original_publish = summary.publish_exclusive
        def publish(source, destination):
            original_publish(source, destination)
            cancelled.set()
        opencc = types.SimpleNamespace(OpenCC=lambda _: types.SimpleNamespace(convert=lambda value: value))
        with patch.object(summary, "physical_memory_bytes", return_value=128 * 1024**3), patch.object(summary, "LocalSummarizer", return_value=DeterministicSummarizer()), patch.object(summary, "publish_exclusive", side_effect=publish), patch.dict(sys.modules, {"opencc": opencc}), self.assertRaises(PipelineError):
            summary.run_summary(self.request(), self.events.append, cancelled.is_set)
        self.assertFalse((self.job / "report.md").exists())
        self.assertFalse((self.job / "transcript.json").exists())
        self.assertTrue(self.source_path.is_file())

    def test_remote_audio_probe_and_decoder_restrict_protocols_and_formats(self):
        payload = {"streams": [{"codec_type": "audio", "index": 0}], "format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2", "duration": "5"}}
        result = types.SimpleNamespace(returncode=0, stdout=json.dumps(payload), stderr="")
        with patch.object(media.subprocess, "run", return_value=result) as process:
            info = media.probe(self.job / "audio.m4a", "/ffprobe", require_video=False, restricted=True)
        command = process.call_args.args[0]
        self.assertEqual(command[command.index("-protocol_whitelist") + 1], "file")
        self.assertEqual(command[command.index("-format_whitelist") + 1], media.REMOTE_FORMATS)
        with patch.object(media, "run_ffmpeg") as encoder:
            media.extract_audio(self.job / "audio.m4a", self.job / "speech.wav", info, "/ffmpeg", Mock(), lambda: False, restricted=True)
        command = encoder.call_args.args[0]
        self.assertLess(command.index("-protocol_whitelist"), command.index("-i"))
        for format_name in ("hls", "concat", "mov,hls", ""):
            payload["format"]["format_name"] = format_name
            result.stdout = json.dumps(payload)
            with patch.object(media.subprocess, "run", return_value=result), self.assertRaises(PipelineError):
                media.probe(self.job / "audio.m4a", "/ffprobe", require_video=False, restricted=True)

    def test_cancel_does_not_publish_or_replace_outputs(self):
        with patch.object(summary, "physical_memory_bytes", return_value=128 * 1024**3), patch.object(summary, "LocalSummarizer") as constructor, self.assertRaises(summary.PipelineError):
            summary.run_summary(self.request(), self.events.append, cancelled=lambda: True)
        constructor.assert_not_called()
        self.assertFalse((self.job / "report.md").exists())

    def test_low_memory_fails_before_loading_model_or_audio(self):
        with patch.object(summary, "physical_memory_bytes", return_value=16 * 1024**3), patch.object(summary, "LocalSummarizer") as constructor, self.assertRaisesRegex(PipelineError, "96 GiB"):
            summary.run_summary(self.request(), self.events.append)
        constructor.assert_not_called()

    def test_renderer_escapes_untrusted_markdown_and_never_fabricates_timestamps(self):
        source = summary.read_source(self.source_path, self.job)
        rows = [{"id": "s1", "source_text": "[unsafe](javascript:alert(1))"}]
        report = report_fixture(rows)
        evidence = {"s1": {**rows[0], "start": 37.8}}
        opencc = types.SimpleNamespace(OpenCC=lambda _: types.SimpleNamespace(convert=lambda value: value))
        with patch.dict(sys.modules, {"opencc": opencc}):
            rendered = summary.render_report(source, report, [{"start": 37.8, "report": report}], evidence)
        self.assertIn("00:00:37", rendered)
        self.assertIn("&t=37", rendered)
        self.assertNotIn("[unsafe](javascript:", rendered)

    def test_model_loading_and_generation_use_local_bf16_and_official_non_thinking_parameters(self):
        items = [{"id": "s1", "source_text": "Verified original quote"}]
        evidence = {"s1": items[0]}
        tokenizer = Mock()
        tokenizer.apply_chat_template.return_value = "formatted prompt"
        tokenizer.return_value = Batch()
        tokenizer.decode.return_value = json.dumps(report_fixture(items))
        model = Mock(device="mps")
        model.eval.return_value = model
        model.generate.return_value = Tensor(20)
        transformers = types.SimpleNamespace(AutoTokenizer=Mock(), AutoModelForCausalLM=Mock())
        transformers.AutoTokenizer.from_pretrained.return_value = tokenizer
        transformers.AutoModelForCausalLM.from_pretrained.return_value = (model, {"missing_keys": [], "mismatched_keys": [], "error_msgs": []})
        with patch.dict(sys.modules, {"torch": fake_torch(), "transformers": transformers}), patch("subtitle_worker.common.cancellation_criteria", return_value=[]):
            loaded = summary.LocalSummarizer(self.model_path, summary.SummaryProgress(self.events.append), lambda: False)
            actual = loaded.generate(items, evidence, "map")
            loaded.close()
        self.assertEqual(actual["covered_ids"], ["s1"])
        options = transformers.AutoModelForCausalLM.from_pretrained.call_args.kwargs
        self.assertTrue(options["local_files_only"])
        self.assertFalse(options["trust_remote_code"])
        self.assertEqual(options["dtype"], "bfloat16")
        self.assertEqual(options["device_map"], {"": "mps"})
        self.assertTrue(options["output_loading_info"])
        self.assertFalse(tokenizer.call_args.kwargs["add_special_tokens"])
        self.assertFalse(tokenizer.apply_chat_template.call_args.kwargs["enable_thinking"])
        generation = model.generate.call_args.kwargs
        self.assertTrue(generation["do_sample"])
        self.assertEqual((generation["temperature"], generation["top_p"], generation["top_k"]), (0.7, 0.8, 20))
        self.assertEqual(generation["max_new_tokens"], summary.OUTPUT_TOKEN_LIMIT)

    def test_missing_text_weights_fail_closed_instead_of_random_initialization(self):
        transformers = types.SimpleNamespace(AutoTokenizer=Mock(), AutoModelForCausalLM=Mock())
        transformers.AutoModelForCausalLM.from_pretrained.return_value = (Mock(), {"missing_keys": ["model.layers.0.weight"]})
        with patch.dict(sys.modules, {"torch": fake_torch(), "transformers": transformers}), self.assertRaisesRegex(PipelineError, "refusing random"):
            summary.LocalSummarizer(self.model_path, summary.SummaryProgress(self.events.append), lambda: False)

    def test_model_invalid_json_and_generation_cap_publish_nothing(self):
        for output_length, text, message in ((10, "<think>hidden</think>{}", "invalid JSON"),
                                             (summary.OUTPUT_TOKEN_LIMIT + 3, "{}", "output limit")):
            with self.subTest(output_length=output_length):
                loaded = object.__new__(summary.LocalSummarizer)
                loaded.torch, loaded.transformers = fake_torch(), object()
                loaded.progress, loaded.cancelled = summary.SummaryProgress(self.events.append), lambda: False
                loaded.model = Mock(device="mps")
                loaded.model.generate.return_value = Tensor(output_length)
                loaded.tokenizer = Mock()
                loaded.tokenizer.apply_chat_template.return_value = "prompt"
                loaded.tokenizer.return_value = Batch()
                loaded.tokenizer.decode.return_value = text
                with patch("subtitle_worker.common.cancellation_criteria", return_value=[]), self.assertRaisesRegex(PipelineError, message):
                    loaded.generate([{ "id": "s1", "source_text": "original"}], {"s1": {"source_text": "original"}}, "map")
                self.assertEqual(loaded.model.generate.call_count, 1 if message == "output limit" else 2)

    def test_invalid_json_retries_once_with_same_model_without_skipping_input(self):
        items = [{"id": "s1", "source_text": "original"}]
        loaded = object.__new__(summary.LocalSummarizer)
        loaded.torch, loaded.transformers = fake_torch(), object()
        loaded.progress, loaded.cancelled = summary.SummaryProgress(self.events.append), lambda: False
        loaded.model = Mock(device="mps")
        loaded.model.generate.return_value = Tensor(20)
        loaded.tokenizer = Mock()
        loaded.tokenizer.apply_chat_template.return_value = "prompt"
        loaded.tokenizer.return_value = Batch()
        loaded.tokenizer.decode.side_effect = ["invalid JSON", json.dumps(report_fixture(items))]
        with patch("subtitle_worker.common.cancellation_criteria", return_value=[]):
            result = loaded.generate(items, {"s1": items[0]}, "map")
        self.assertEqual(result["covered_ids"], ["s1"])
        self.assertEqual(loaded.model.generate.call_count, 2)
        self.assertTrue(any("Retrying" in event["message"] for event in self.events))


def summary_manifest():
    manifest = fixture_manifest()
    model = copy.deepcopy(manifest["models"][0])
    model.update(id="summarizer", name="summarizer", directory="models/summarizer")
    artifact = model["artifacts"][0]
    artifact.update(id="summarizer", path="models/summarizer/weights")
    manifest["models"].append(model)
    return manifest


class SummarySupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chengying-summary-supervisor-")
        self.root = Path(self.temporary.name).resolve()
        self.events = []
        self.supervisor = Supervisor(summary_manifest(), "lock", self.root, self.root, "/ffmpeg", "/ffprobe", self.events.append,
                                     downloader_helper=sys.executable, downloader_data_dir=str(self.root / "DownloadCenter"))
    def tearDown(self):
        self.supervisor.close()
        self.temporary.cleanup()

    def test_purpose_selects_exact_models_without_translation_download(self):
        for purpose, expected in (("summary", {"asr", "aligner", "summarizer"}), ("subtitles", {"asr", "aligner", "translator"})):
            ensured = []
            with patch.object(self.supervisor.store, "ensure", side_effect=lambda artifact, *_, captured=ensured: captured.append(artifact.id)), patch.object(self.supervisor.runtime, "ready", return_value=True), patch.object(self.supervisor.runtime, "ensure"):
                self.supervisor.request({"id": purpose, "command": "prepare", "purpose": purpose})
                self.supervisor._thread.join(3)
            self.assertEqual(self.events[-1]["type"], "completed")
            self.assertEqual(set(ensured) - {"python", "wheel"}, expected)

    def test_source_subtitles_only_require_summarizer_and_output_uses_request_uuid(self):
        identifier = str(uuid.uuid4()).upper()
        checked, payloads = [], []
        def source(command, cancel, output, **kwargs):
            job = Path(command[command.index("--download-dir") + 1])
            self.assertEqual(job, self.root / "summaries" / identifier / "source")
            self.assertIn("--summary-source", command)
            self.assertEqual(json.loads(kwargs["stdin_payload"])["id"], identifier)
            path = job / "source.json"
            path.write_text(json.dumps(source_fixture()))
            output(json.dumps({"type": "completed", "id": identifier, "source_path": str(path)}))
            return 0
        def worker(payload, emit):
            payloads.append(payload)
            emit({"type": "completed", "outputs": {"summary": payload["output_dir"] + "/report.md"}})
        with patch("subtitle_worker.common.physical_memory_bytes", return_value=128 * 1024**3), patch.object(self.supervisor.runtime, "ready", return_value=True), patch.object(self.supervisor.store, "verify", side_effect=lambda artifact, *_: checked.append(artifact.id) or artifact.id == "summarizer"), patch("helper.run_process", side_effect=source), patch.object(self.supervisor, "_worker", side_effect=worker):
            self.supervisor.request({"id": identifier, "command": "summarize", "source_url": source_fixture()["source_url"]})
            self.supervisor._thread.join(3)
        self.assertEqual(self.events[-1]["type"], "completed", self.events)
        self.assertEqual(checked, ["summarizer"])
        self.assertEqual(payloads[0]["operation"], "summary")
        self.assertEqual(self.events[-1]["operation"], "summary")
        self.assertIsNone(self.events[-1]["active_id"])

    def test_audio_fallback_checks_asr_and_fails_without_downloading_it(self):
        identifier = str(uuid.uuid4())
        def source(command, cancel, output, **kwargs):
            job = Path(command[command.index("--download-dir") + 1])
            audio = job / "speech.m4a"
            audio.write_bytes(b"audio")
            value = {**source_fixture(), "content_source": "audio", "audio_path": str(audio), "segments": []}
            path = job / "source.json"
            path.write_text(json.dumps(value))
            output(json.dumps({"type": "completed", "id": identifier, "source_path": str(path)}))
            return 0
        checked = []
        with patch("subtitle_worker.common.physical_memory_bytes", return_value=128 * 1024**3), patch.object(self.supervisor.runtime, "ready", return_value=True), patch.object(self.supervisor.store, "verify", side_effect=lambda artifact, *_: checked.append(artifact.id) or artifact.id == "summarizer"), patch.object(self.supervisor.store, "ensure") as download, patch("helper.run_process", side_effect=source), patch.object(self.supervisor, "_worker") as worker:
            self.supervisor.request({"id": identifier, "command": "summarize", "source_url": source_fixture()["source_url"]})
            self.supervisor._thread.join(3)
        self.assertEqual(self.events[-1]["type"], "failed")
        self.assertIn("asr", checked)
        self.assertNotIn("translator", checked)
        download.assert_not_called()
        worker.assert_not_called()

    def test_held_stdin_is_not_closed_before_source_child_exits(self):
        program = "import sys,select; line=sys.stdin.readline(); print(line.strip(),flush=True); print('open' if not select.select([sys.stdin],[],[],0.1)[0] else 'closed',flush=True)"
        lines = []
        code = run_process([sys.executable, "-u", "-c", program], threading.Event(), lines.append, stdin_payload='{"id":"test"}')
        self.assertEqual(code, 0)
        self.assertEqual(lines, ['{"id":"test"}', "open"])

    def test_invalid_uuid_cannot_create_output_directory(self):
        with patch("subtitle_worker.common.physical_memory_bytes", return_value=128 * 1024**3), patch.object(self.supervisor.runtime, "ready", return_value=True), patch.object(self.supervisor.store, "verify", return_value=True), patch("helper.run_process") as source:
            self.supervisor.request({"id": "../../outside", "command": "summarize", "source_url": source_fixture()["source_url"]})
            self.supervisor._thread.join(3)
        self.assertEqual(self.events[-1]["type"], "failed")
        source.assert_not_called()
        self.assertFalse((self.root / "summaries").exists())


class RuntimeMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chengying-runtime-migration-")
        self.root = Path(self.temporary.name).resolve()
        self.manifest = fixture_manifest()
        self.runtime = Runtime(self.root, self.manifest, "legacy")
        executable = self.runtime.directory / "python/bin/python3"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"python")
        self.marker = self.runtime.directory / ".ready.json"
        self.marker.write_text(json.dumps({"validation_version": 1, "manifest_sha256": "legacy", "python_sha256": hashlib.sha256(b"python").hexdigest()}))
        for specification in [self.manifest["runtime"]["archive"], *self.manifest["runtime"]["wheels"]]:
            path = self.root / specification["path"]
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"x")
    def tearDown(self):
        self.temporary.cleanup()

    def test_verified_runtime_migrates_without_install_and_model_changes_keep_it_ready(self):
        with patch("runtime.run_process") as installer:
            self.runtime.ensure(threading.Event(), lambda event: None)
        installer.assert_not_called()
        self.assertTrue(self.runtime.ready())
        changed = copy.deepcopy(self.manifest)
        changed["models"] = summary_manifest()["models"]
        self.assertTrue(Runtime(self.root, changed, "different-whole-manifest").ready())

    def test_corrupt_archive_does_not_migrate_marker(self):
        (self.root / self.manifest["runtime"]["archive"]["path"]).write_bytes(b"wrong")
        self.assertFalse(self.runtime._migrate_marker(threading.Event(), lambda event: None))
        self.assertEqual(json.loads(self.marker.read_text())["manifest_sha256"], "legacy")

    def test_previous_manifest_migration_is_bound_to_exact_runtime_fingerprint(self):
        self.manifest["legacy_runtime_manifests"] = {"legacy": self.runtime.fingerprint}
        valid = Runtime(self.root, self.manifest, "new-lock")
        self.assertIn("legacy", valid.legacy_fingerprints)
        self.manifest["runtime"]["requirements"] = ["test==2.0 --hash=sha256:" + "b" * 64]
        different = Runtime(self.root, self.manifest, "newer-lock")
        self.assertNotIn("legacy", different.legacy_fingerprints)
        self.assertFalse(different._migrate_marker(threading.Event(), lambda event: None))

    def test_cancellation_is_not_swallowed_during_migration(self):
        cancel = threading.Event()
        cancel.set()
        with self.assertRaises(Cancelled):
            self.runtime._migrate_marker(cancel, lambda event: None)


if __name__ == "__main__":
    unittest.main()
