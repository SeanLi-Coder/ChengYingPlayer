#!/usr/bin/env python3
"""Non-GUI controls for the production seek-event extraction boundary."""

import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("seek_timing_runner", Path(__file__).with_name("run.py"))
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)

HANDLER = """  private func handleEvent(_ event: UnsafePointer<mpv_event>) {
    switch eventId {
    case MPV_EVENT_SHUTDOWN:
      cancelSeekTiming()
    case MPV_EVENT_START_FILE:
      cancelSeekTiming()
    case MPV_EVENT_SEEK:
      let seekTime = CACurrentMediaTime()
      DispatchQueue.main.async {
        observeSeekTiming(token: timingToken, at: seekTime)
      }
    case MPV_EVENT_PLAYBACK_RESTART:
      let restartTime = CACurrentMediaTime()
      DispatchQueue.main.async {
        finishSeekTiming(token: timingToken, at: restartTime)
        markSeekTimingPlaybackReady(token: timingToken)
      }
    case MPV_EVENT_END_FILE:
      cancelSeekTiming()
    case MPV_EVENT_QUEUE_OVERFLOW:
      cancelSeekTiming()
    default: break
    }
  }
"""
OTHER = """  private func routeNativeQueueEvent(_ event: UnsafePointer<mpv_event>) -> Bool {
    switch eventId {
    case MPV_EVENT_PLAYBACK_RESTART:
      forwardNativeRestart()
    case MPV_EVENT_END_FILE:
      forwardNativeEnd()
    default: break
    }
    return true
  }
"""


class EventBoundaryTests(unittest.TestCase):
    def test_unique_handler_without_another_router(self):
        self.assertEqual(RUNNER.event_handler(HANDLER), HANDLER.rstrip("\n"))
        RUNNER.validate_event_wiring(HANDLER)

    def test_duplicate_event_in_another_method_before_or_after_is_supported(self):
        for source in (OTHER + HANDLER, HANDLER + OTHER):
            with self.subTest(before=source.startswith(OTHER)):
                self.assertEqual(source.count("    case MPV_EVENT_PLAYBACK_RESTART:"), 2)
                self.assertEqual(RUNNER.event_handler(source), HANDLER.rstrip("\n"))
                RUNNER.validate_event_wiring(source)
                with self.assertRaisesRegex(RuntimeError, "Production extraction boundary changed"):
                    RUNNER.section(source, "    case MPV_EVENT_PLAYBACK_RESTART:", "\n    case ")

    def test_current_production_handler_satisfies_the_original_wiring_assertions(self):
        source = (ROOT / "iina/MPVController.swift").read_text()
        RUNNER.validate_event_wiring(source)
        handler = RUNNER.event_handler(source)
        self.assertEqual(handler.count("    case MPV_EVENT_PLAYBACK_RESTART:"), 1)
        self.assertIn("let restartTime = CACurrentMediaTime()", handler)
        self.assertNotIn("forwarded = .playbackRestart", handler)

    def test_missing_handler_fails_closed(self):
        with self.assertRaisesRegex(RuntimeError, "Production extraction boundary changed"):
            RUNNER.event_handler(OTHER)

    def test_duplicate_handler_fails_closed(self):
        with self.assertRaisesRegex(RuntimeError, "Production extraction boundary changed"):
            RUNNER.event_handler(HANDLER + OTHER + HANDLER)

    def test_missing_closing_boundary_fails_closed(self):
        missing_close = HANDLER.removesuffix("  }\n")
        with self.assertRaisesRegex(RuntimeError, "closing boundary changed"):
            RUNNER.event_handler(missing_close)
        with self.assertRaisesRegex(RuntimeError, "ambiguous method boundary"):
            RUNNER.event_handler(missing_close + OTHER)

    def test_duplicate_case_inside_handler_still_fails(self):
        duplicate = HANDLER.replace("    case MPV_EVENT_END_FILE:",
                                    "    case MPV_EVENT_PLAYBACK_RESTART:\n    case MPV_EVENT_END_FILE:")
        with self.assertRaisesRegex(RuntimeError, "Production extraction boundary changed"):
            RUNNER.validate_event_wiring(OTHER + duplicate)

    def test_other_router_cannot_supply_missing_handler_case(self):
        broken = HANDLER.replace("    case MPV_EVENT_PLAYBACK_RESTART:", "    case MPV_EVENT_NONE:")
        with self.assertRaisesRegex(RuntimeError, "Production extraction boundary changed"):
            RUNNER.validate_event_wiring(OTHER + broken)

    def test_other_method_cannot_supply_missing_lifecycle_invalidation(self):
        broken = HANDLER.replace("case MPV_EVENT_END_FILE:\n      cancelSeekTiming()",
                                 "case MPV_EVENT_END_FILE:\n      ignoreEnd()")
        other = OTHER.replace("forwardNativeEnd()", "cancelSeekTiming()")
        with self.assertRaisesRegex(RuntimeError, "Missing lifecycle invalidation: END_FILE"):
            RUNNER.validate_event_wiring(other + broken)

    def test_timestamp_capture_must_still_precede_dispatch(self):
        broken = HANDLER.replace("      let restartTime = CACurrentMediaTime()\n      DispatchQueue.main.async {",
                                 "      DispatchQueue.main.async {\n      let restartTime = CACurrentMediaTime()")
        with self.assertRaisesRegex(RuntimeError, "captured before main-queue dispatch"):
            RUNNER.validate_event_wiring(OTHER + broken)

    def test_captured_values_must_still_be_delivered_unchanged(self):
        broken = HANDLER.replace("finishSeekTiming(token: timingToken, at: restartTime)",
                                 "finishSeekTiming(token: currentToken, at: restartTime)")
        with self.assertRaisesRegex(RuntimeError, "captured timing values unchanged"):
            RUNNER.validate_event_wiring(OTHER + broken)

    def test_restart_readiness_must_still_use_captured_token(self):
        broken = HANDLER.replace("markSeekTimingPlaybackReady(token: timingToken)",
                                 "markSeekTimingPlaybackReady(token: currentToken)")
        with self.assertRaisesRegex(RuntimeError, "captured restart generation"):
            RUNNER.validate_event_wiring(OTHER + broken)


if __name__ == "__main__":
    unittest.main(verbosity=2)
