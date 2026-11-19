"""Offline subtitle checkpoint persistence and retry tests."""
from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
import unittest
from contextlib import chdir
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from subtitle_worker import pipeline
from subtitle_worker.checkpoint import open_checkpoint
from subtitle_worker.common import Cancelled, PipelineError, Segment


class CheckpointTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.video = self.root / "sample.mov"
        self.video.write_bytes(b"media")
        self.data = self.root / "app-support"
        self.cache = self.data / "subtitle-checkpoints"
        self.paths = {"asr": str(self.root / "asr")}
        self.cues = [Segment(i, i + 1, f"source {i}", f"source {i}", "English") for i in range(3)]

    def open(self, language="auto", paths=None):
        return open_checkpoint(self.data, self.video, language, self.paths if paths is None else paths)

    def save(self):
        with self.open() as checkpoint:
            checkpoint.save_transcript(self.cues)
            checkpoint.save_translations({0: "translation zero", 2: "translation two"})

    def test_partial_batches_commit_and_only_explicit_translations_are_restored(self):
        self.save()
        with self.open() as checkpoint:
            cues, restored = checkpoint.load()
            self.assertEqual([c.source_text for c in cues], [c.source_text for c in self.cues])
            self.assertEqual([c.text for c in cues], [""] * 3)
            self.assertEqual(restored, {0: "translation zero", 2: "translation two"})
            with self.assertRaisesRegex(PipelineError, "does not match"):
                checkpoint.save_translations({1: "new", 123: "outside"})
        with self.open() as checkpoint:
            self.assertNotIn(1, checkpoint.load()[1])
            checkpoint.completed = True
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_identity_includes_language_source_path_content_and_model_paths(self):
        self.save()
        with self.open(language="English") as checkpoint:
            self.assertEqual(checkpoint.load(), ([], {}))
        with self.open(paths={"asr": str(self.root / "different")}) as checkpoint:
            self.assertEqual(checkpoint.load(), ([], {}))
        copy = self.root / "other.mov"
        os.link(self.video, copy)
        with open_checkpoint(self.data, copy, "auto", self.paths) as checkpoint:
            self.assertEqual(checkpoint.load(), ([], {}))
        self.save()
        stamp = self.video.stat()
        self.video.write_bytes(b"abcde")
        os.utime(self.video, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        with self.open() as checkpoint:
            self.assertEqual(checkpoint.load(), ([], {}))

    def test_replaced_model_asset_in_same_directory_starts_fresh(self):
        model = Path(self.paths["asr"])
        model.mkdir()
        config = model / "config.json"
        config.write_text("first")
        self.save()
        config.write_text("changed")
        with self.open() as checkpoint:
            self.assertEqual(checkpoint.load(), ([], {}))

    def test_concurrent_worker_cannot_overwrite_progress(self):
        with self.open() as active:
            active.save_transcript(self.cues)
            with self.assertRaisesRegex(PipelineError, "Another subtitle operation"), self.open():
                self.fail("A second worker unexpectedly acquired the checkpoint")
            active.save_translations({1: "durable"})
        with self.open() as checkpoint:
            self.assertEqual(checkpoint.load()[1], {1: "durable"})

    def test_worker_process_exit_preserves_committed_progress(self):
        code = """
import os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from subtitle_worker.checkpoint import open_checkpoint
from subtitle_worker.common import Segment
with open_checkpoint(sys.argv[2], Path(sys.argv[3]), 'auto', {'asr': sys.argv[4]}) as checkpoint:
    checkpoint.save_transcript([Segment(0, 2, 'source', language='English')])
    checkpoint.save_translations({0: 'completed translation'})
    os._exit(42)
"""
        proc = subprocess.run([sys.executable, "-BI", "-c", code, str(Path(__file__).resolve().parents[1]),
                               str(self.data), str(self.video), self.paths["asr"]], timeout=20, check=False)
        self.assertEqual(proc.returncode, 42)
        with self.open() as checkpoint:
            self.assertEqual(checkpoint.load()[1], {0: "completed translation"})

    def test_damaged_cache_starts_fresh(self):
        self.save()
        database, = self.cache.iterdir()
        database.write_bytes(b"damaged cache")
        with self.open() as checkpoint:
            self.assertEqual(checkpoint.load(), ([], {}))
            checkpoint.save_transcript(self.cues)
        with self.open() as checkpoint:
            self.assertEqual(len(checkpoint.load()[0]), 3)

    def test_explicit_models_without_data_directory_use_ephemeral_storage(self):
        callback = mock.Mock()
        with self.assertRaises(PipelineError), open_checkpoint(
                None, self.video, "auto", self.paths, on_retained=callback) as checkpoint:
            checkpoint.save_transcript(self.cues)
            raise PipelineError("interrupted")
        with open_checkpoint("", self.video, "auto", self.paths) as checkpoint:
            self.assertEqual(checkpoint.load(), ([], {}))
        with chdir(self.root), open_checkpoint("app-support", self.video, "auto", self.paths) as checkpoint:
            checkpoint.save_transcript(self.cues)
        callback.assert_not_called()
        self.assertFalse(self.data.exists())

    def test_checkpoint_is_private_and_no_directory_or_rollback_links_followed(self):
        self.save()
        self.assertEqual(stat.S_IMODE(self.cache.stat().st_mode), 0o700)
        database, = self.cache.iterdir()
        self.assertEqual(stat.S_IMODE(database.stat().st_mode), 0o600)
        self.assertNotIn(self.video.stem, database.name)
        other = self.root / "outside"
        other.write_text("keep")
        Path(str(database) + "-journal").symlink_to(other)
        with self.assertRaisesRegex(PipelineError, "unexpected link"), self.open():
            pass
        self.assertEqual(other.read_text(), "keep")
        self.cache.rename(self.root / "original-cache")
        self.cache.symlink_to(self.root / "original-cache", target_is_directory=True)
        with self.assertRaisesRegex(PipelineError, "unexpected link"), self.open():
            pass

    def test_restart_skips_audio_and_asr_keeps_cue_indices_and_removes_checkpoint_on_success(self):
        request = {"input_path": str(self.video), "data_dir": str(self.data), "language": "auto",
                   "ffmpeg": sys.executable, "ffprobe": sys.executable}

        def first(cues, paths, progress, cancelled, restored, save):
            self.assertEqual(restored, {})
            self.assertEqual([c.text for c in cues], [""] * 3)
            save({1: "middle translation"})
            raise Cancelled("cancel after one translated cue")

        def resume(cues, paths, progress, cancelled, restored, save):
            self.assertEqual(restored, {1: "middle translation"})
            for i, item in enumerate(cues):
                item.text = restored.get(i, f"translated {i}")
            save({0: cues[0].text, 2: cues[2].text})
            return cues

        events = []
        with (mock.patch.object(pipeline, "probe", return_value={"duration": 3}),
              mock.patch.object(pipeline, "extract_audio") as extract,
              mock.patch.object(pipeline, "transcribe", return_value=self.cues) as transcribe):
            with mock.patch.object(pipeline, "translate", side_effect=first), self.assertRaises(Cancelled):
                pipeline.run_pipeline(request, events.append)
            self.assertIs(events[-1].get("checkpoint_retained"), True)
            self.assertFalse(list(self.root.glob("*.srt")))
            self.assertFalse(list(self.root.glob(".chengying-subtitles-*")))
            with mock.patch.object(pipeline, "translate", side_effect=resume):
                result = pipeline.run_pipeline(request, events.append)
        extract.assert_called_once()
        transcribe.assert_called_once()
        text = Path(result["outputs"]["srt"]).read_text()
        self.assertLess(text.index("translated 0"), text.index("middle translation"))
        self.assertLess(text.index("middle translation"), text.index("translated 2"))
        self.assertNotIn("source", text)
        resumed, = (e for e in events if "resumed_cues" in e)
        self.assertEqual((resumed["resumed_cues"], resumed["resumed_translations"]), (3, 1))
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_incomplete_translation_cannot_fall_back_to_asr_text(self):
        request = {"input_path": str(self.video), "data_dir": str(self.data), "language": "auto",
                   "ffmpeg": sys.executable, "ffprobe": sys.executable}
        with (mock.patch.object(pipeline, "probe", return_value={"duration": 3}),
              mock.patch.object(pipeline, "extract_audio"),
              mock.patch.object(pipeline, "transcribe", return_value=self.cues),
              mock.patch.object(pipeline, "translate", side_effect=lambda cues, *args: cues),
              self.assertRaisesRegex(PipelineError, "did not finish every subtitle")):
            pipeline.run_pipeline(request, lambda e: None)
        self.assertFalse(list(self.root.glob("*.srt")))
        self.assertTrue(list(self.cache.iterdir()))

    def test_source_changed_during_recognition_is_not_checkpointed(self):
        with self.open() as checkpoint:
            self.video.write_bytes(b"replaced")
            with self.assertRaisesRegex(PipelineError, "changed during subtitle"):
                checkpoint.save_transcript(self.cues)
        with self.open() as checkpoint:
            self.assertEqual(checkpoint.load(), ([], {}))

    def test_changed_source_omits_unusable_recovery_hint(self):
        callback = mock.Mock()
        with self.assertRaisesRegex(PipelineError, "changed"), open_checkpoint(
                self.data, self.video, "auto", self.paths, on_retained=callback) as checkpoint:
            checkpoint.save_transcript(self.cues)
            self.video.write_bytes(b"changed source")
            checkpoint.check_source()
        callback.assert_not_called()
