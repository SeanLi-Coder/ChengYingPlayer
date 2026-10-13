#!/usr/bin/env python3
"""Build and exercise the complete native playback App on a disposable CI Mac."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from other.test_app_workspace import TestAppWorkspace

REQUIRED_CHECKS = {
    "pristine_real_mpv_service", "native_autoplay_ready", "native_autoplay_shared_clock_advances",
    "real_mainwindow_nib_outlets", "paused_initial_frame_matches_red",
    "initial_volume_and_slider_zero", "native_window_has_no_compatibility_gl", "real_pause_menu_action",
    "paused_clock_stays_still", "real_volume_slider_action", "paused_seek_presents_green_frame",
    "rapid_replace_presents_latest_blue_frame", "retired_layer_detached", "replacement_resets_volume_and_slider",
    "real_window_close_retires_native_session", "embedded_subtitle_routes_to_real_compatibility",
    "compatibility_open_remains_silent", "second_pristine_real_mpv_service",
    "second_native_paused_blue_frame", "second_real_resume_menu_action", "resumed_native_shared_clock_advances",
    "native_and_compatibility_ready_for_real_quit", "all_real_cores_shutdown_before_termination",
    "ab_key_window_ready", "ab_start_is_exact_zero", "ab_left_bracket_shows_zero_marker",
    "ab_equal_end_key_is_rejected", "ab_end_capture_position_is_green",
    "ab_right_bracket_shows_valid_paused_range", "ab_invalid_end_edits_preserve_range",
    "ab_invalid_dragged_a_restores_visible_marker", "ab_invalid_dragged_b_restores_visible_marker",
    "ab_file_loop_selection_keeps_markers", "ab_absolute_seek_stays_before_end",
    "ab_relative_seek_stays_at_start", "ab_menu_clear_preserves_file_loop",
    "ab_menu_cycle_sets_a", "ab_menu_end_position_is_green", "ab_menu_cycle_sets_b",
    "ab_menu_cycle_clears_range", "ab_cleanup_remains_native_without_gl",
    "delayed_native_paused_open_ready", "delayed_paused_first_frame_at_zero",
    "delayed_paused_shared_clock_stays_still", "delayed_real_resume_menu_action",
    "delayed_resume_ready", "delayed_resume_shared_clock_advances",
    "viewport_key_window_ready", "viewport_initial_attached_geometry",
    "viewport_zoom_in_key_updates_layer", "viewport_zoom_out_key_updates_layer",
    "viewport_pan_setup_zoomed", "viewport_pan_right_key_updates_layer",
    "viewport_pan_left_key_updates_layer", "viewport_pan_up_key_updates_layer",
    "viewport_pan_down_key_updates_layer", "viewport_resize_recomputes_normalized_pan",
    "viewport_reset_key_restores_fit", "viewport_window_and_state_restored",
    "viewport_paused_clock_stays_still",
    "preview_baseline_paused_red", "preview_real_tools_menu_attached", "preview_tools_auto_preview",
    "preview_auto_shared_clock_advances", "preview_fields_debounce_pending", "preview_latest_fields_apply",
    "preview_chrome_actually_hides", "preview_hidden_chrome_keeps_looping",
    "preview_stop_button_restores_state", "preview_stopped_stays_stopped", "preview_manual_seek_cancels",
    "preview_manual_seek_stays_cancelled", "preview_panel_close_remains_native",
    "preview_window_close_begins_with_applied_range", "preview_window_close_cancels_and_detaches",
    "handoff_pristine_real_mpv_service", "handoff_native_paused_red_ready", "handoff_key_window_ready",
    "handoff_zero_a_marker", "handoff_end_capture_green", "handoff_ab_range_ready", "handoff_paused_green_target",
    "handoff_native_nondefault_state", "handoff_real_audio_delay_menu_action", "handoff_same_window_mpv_ready",
    "handoff_native_resources_detached", "handoff_mpv_transport_restored", "handoff_mpv_viewport_and_ab_restored",
    "handoff_deferred_menu_action_applied", "handoff_paused_mpv_stays_still", "handoff_real_close_stops_mpv",
    "handoff_extra_core_shutdown",
    "handoff_native_ontop_menu_state", "handoff_mpv_window_options_restored", "handoff_mpv_window_options_stable",
}
QUEUE_REQUIRED_CHECKS = {
    "queue_cancel_pristine_service", "queue_cancel_native_plan_ready", "queue_cancel_during_partial_install",
    "queue_cancel_reopens_compatibility", "queue_cancel_reopened_remains_owned",
    "queue_cancel_core_close", "queue_cancel_core_shutdown",
    "queue_pristine_service", "queue_explicit_duplicate_urls_accepted", "queue_first_actual_red_frame",
    "queue_distinct_duplicate_identities", "queue_volume_before_next", "queue_next_blue_resets_volume",
    "queue_volume_before_previous", "queue_previous_red_resets_volume", "queue_volume_before_duplicate",
    "queue_selected_duplicate_resets_volume", "queue_loading_latest_pause_intent", "queue_loading_pause_clock_stable",
    "queue_last_item_ready_for_eof", "queue_off_last_seek_near_eof", "queue_off_last_reaches_real_eof",
    "queue_eof_seek_preserves_target", "queue_eof_seek_resume_not_rewound", "queue_eof_seek_actual_clock_advances",
    "queue_eof_resume_paused", "queue_file_seek_near_eof", "queue_file_wraps_same_duplicate",
    "queue_list_seek_near_eof", "queue_list_wraps_to_first_duplicate", "queue_auto_advance_without_opening_pause",
    "queue_new_open_cancels_pending_selection",
    "queue_cancelled_selection_stays_cancelled", "queue_reopen_for_loaded_handoff", "queue_handoff_duplicate_selected",
    "queue_handoff_key_window", "queue_handoff_zero_a", "queue_handoff_b_capture", "queue_handoff_ab_ready",
    "queue_handoff_green_target", "queue_handoff_state_ready", "queue_real_menu_handoff",
    "queue_loaded_whole_plan_mpv_restored", "queue_loaded_handoff_same_window_detached", "queue_loaded_handoff_remains_paused",
    "queue_first_core_close", "queue_first_core_shutdown", "queue_second_pristine_service",
    "queue_unsupported_plan_initial_red", "queue_unsupported_whole_plan_fallback", "queue_unsupported_old_layer_detached",
    "queue_second_core_close", "queue_second_core_shutdown", "queue_all_registered_cores_shutdown",
}
RESUME_REQUIRED_CHECKS = {
    "resume_isolated_state", "resume_stop_pristine", "resume_stop_initial", "resume_stop_ready",
    "resume_stop_closed", "resume_stop_saved_fields", "resume_stop_shutdown",
    "resume_reopen_pristine", "resume_reopen_actual_mpv", "resume_reopen_consumed", "resume_reopen_stable",
    "resume_reopen_closed", "resume_reopen_shutdown", "resume_preview_prepare_clear",
    "resume_preview_pristine", "resume_preview_initial", "resume_preview_ready", "resume_preview_menu_attached",
    "resume_preview_clock_in_range", "resume_preview_restore_pending", "resume_preview_closed",
    "resume_preview_baseline_saved", "resume_preview_shutdown", "resume_clear_prepare_clear",
    "resume_clear_pristine", "resume_clear_initial", "resume_clear_ready", "resume_clear_completed",
    "resume_clear_closed", "resume_clear_no_refill", "resume_clear_shutdown",
    "resume_optout_pristine", "resume_optout_initial", "resume_optout_ready", "resume_optout_applied",
    "resume_optout_closed", "resume_optout_no_refill", "resume_optout_shutdown",
    "resume_quit_pristine", "resume_quit_initial", "resume_quit_ready",
    "resume_quit_record_absent_before_terminate", "resume_all_registered_cores_shutdown", "resume_quit_saved_fields",
}
RESUME_VERIFY_REQUIRED_CHECKS = {
    "resume_verify_isolated_state", "resume_verify_quit_saved_fields", "resume_verify_pristine",
    "resume_verify_actual_mpv", "resume_verify_consumed", "resume_verify_stable",
    "resume_verify_closed", "resume_verify_no_refill", "resume_verify_shutdown",
    "resume_verify_all_registered_cores_shutdown",
}
PIXEL_POINTS = [(x, y) for y in (8, 48, 86) for x in (8, 80, 150)]
MAX_REPORT_BYTES = 1024 * 1024


def validate_environment(environment):
    if (sys.platform != "darwin" or environment.get("CI") != "true" or
            environment.get("GITHUB_ACTIONS") != "true" or environment.get("RUNNER_ENVIRONMENT") != "github-hosted"):
        raise ValueError("Full App tests require a disposable GitHub Actions macOS runner.")
    if any(name.startswith("DYLD_") or name == "LD_LIBRARY_PATH" for name in environment):
        raise ValueError("Inherited dynamic loader overrides are not allowed.")


def validate_result(result, *, run_id, exit_code, required_checks=REQUIRED_CHECKS):
    if (exit_code != 0 or result.get("format") != 1 or result.get("run_id") != run_id or
            result.get("complete") is not True or result.get("passed") is not True):
        raise RuntimeError("Complete App execution or shutdown verification failed.")
    checks = result.get("checks")
    if (not isinstance(checks, list) or len(checks) != len(required_checks) or
            any(not isinstance(item, dict) or item.get("passed") is not True for item in checks) or
            {item.get("label") for item in checks} != required_checks):
        raise RuntimeError("Complete App checks are missing, repeated or unsuccessful.")
    return checks


def preserve_result(fixture_root, report, run_id, *, required_checks=REQUIRED_CHECKS, result_filename="result.json"):
    """Retain bounded, run-owned evidence before workspace cleanup, even on timeout."""
    if result_filename not in {"result.json", "result-resume-verify.json"}:
        raise RuntimeError("Unexpected test report filename.")
    output = fixture_root / result_filename
    try:
        details = output.lstat()
    except FileNotFoundError:
        return None
    if (not stat.S_ISREG(details.st_mode) or output.resolve() != output or
            details.st_size <= 0 or details.st_size > MAX_REPORT_BYTES):
        raise RuntimeError("The test result is not a bounded regular report.")
    descriptor = os.open(output, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        opened = os.fstat(stream.fileno())
        if (not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) !=
                (details.st_dev, details.st_ino)):
            raise RuntimeError("The test result changed while opening it.")
        data = stream.read(MAX_REPORT_BYTES + 1)
    if not data or len(data) > MAX_REPORT_BYTES:
        raise RuntimeError("The test result exceeds its evidence limit.")
    result = json.loads(data)
    if (not isinstance(result, dict) or set(result) != {"format", "run_id", "complete", "passed", "checks"} or
            type(result.get("format")) is not int or result.get("format") != 1 or result.get("run_id") != run_id or
            type(result.get("complete")) is not bool or type(result.get("passed")) is not bool or
            not isinstance(result.get("checks"), list) or len(result["checks"]) > len(required_checks) + 1 or
            any(not isinstance(item, dict) or set(item) != {"label", "passed"} or
                not isinstance(item["label"], str) or not re.fullmatch(r"[a-z][a-z0-9_]{0,127}", item["label"]) or
                type(item["passed"]) is not bool for item in result["checks"])):
        raise RuntimeError("The test result does not belong to the current run.")
    (report / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def fingerprint_inputs(inputs):
    files = []
    for path in inputs:
        files.extend(sorted(p for p in path.rglob("*") if p.is_file()) if path.is_dir() else [path])
    result = {}
    for path in files:
        if not path.is_file():
            raise RuntimeError("An identity input is missing.")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        result[str(path)] = digest.hexdigest()
    if not result:
        raise RuntimeError("Identity input inventory is empty.")
    return result


def snapshot_identity(groups, report):
    expected = {name: fingerprint_inputs(inputs) for name, inputs in groups.items()}
    for name, manifest in expected.items():
        (report / (name + "-sha256.json")).write_text(json.dumps(manifest, indent=2) + "\n")
    return expected


def verify_identity(groups, expected, report, *, stage):
    validation = {"stage": stage, "passed": False, "groups": {}}
    try:
        for name, inputs in groups.items():
            current = fingerprint_inputs(inputs)
            (report / (name + "-sha256-after.json")).write_text(json.dumps(current, indent=2) + "\n")
            previous = expected[name]
            changed = sorted(path for path in previous.keys() | current.keys() if previous.get(path) != current.get(path))
            validation["groups"][name] = {"passed": not changed, "files": len(current), "changed": changed}
        if not all(item["passed"] for item in validation["groups"].values()):
            raise RuntimeError("Native App source, product or fixture identity changed during execution.")
        validation["passed"] = True
    finally:
        (report / (stage + "-identity-validation.json")).write_text(json.dumps(validation, indent=2) + "\n")


def run_application(command, *, workspace, environment, log, fixtures, report, run_id, timeout=150,
                    required_checks=REQUIRED_CHECKS, identity_groups=None, identity_expected=None,
                    result_filename="result.json"):
    result_data = None
    execution = {"run_id": run_id, "started": False, "exit_code": None, "timed_out": False}
    try:
        if identity_groups is not None:
            verify_identity(identity_groups, identity_expected, report, stage="before-process")
        execution["started"] = True
        result = subprocess.run(command, cwd=workspace, env=environment, stdin=subprocess.DEVNULL,
                                stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        execution["exit_code"] = result.returncode
    except subprocess.TimeoutExpired:
        execution["timed_out"] = True
        raise
    finally:
        (report / "process-status.json").write_text(json.dumps(execution, indent=2) + "\n")
        # A partial report is diagnostic evidence only. validate_result still
        # requires clean process exit, all checks and the final shutdown record.
        try:
            result_data = preserve_result(fixtures, report, run_id, required_checks=required_checks,
                                          result_filename=result_filename)
        finally:
            if identity_groups is not None:
                verify_identity(identity_groups, identity_expected, report, stage="after-process")
    return result, result_data


def pixel_reference(ffmpeg, source, seconds):
    raw = subprocess.check_output([str(ffmpeg), "-hide_banner", "-loglevel", "error", "-nostdin",
        "-ss", str(seconds), "-i", str(source), "-frames:v", "1", "-an", "-pix_fmt", "nv12",
        "-f", "rawvideo", "pipe:1"], timeout=15)
    width, height = 160, 96
    if len(raw) != width * height * 3 // 2:
        raise RuntimeError("The independent fixture decode changed its dimensions.")
    result = []
    for x, y in PIXEL_POINTS:
        chroma = width * height + (y // 2) * width + (x // 2) * 2
        result += [raw[y * width + x], raw[chroma], raw[chroma + 1]]
    return result


def make_fixtures(root, run_id):
    ffmpeg = ROOT / "deps/executable/ffmpeg"
    for name in ("red", "blue", "compat", "delayed"):
        (root / name).mkdir()
    base = [str(ffmpeg), "-hide_banner", "-loglevel", "error", "-nostdin"]
    settings = ["-c:v", "libx264", "-preset", "medium", "-crf", "18", "-bf", "2", "-g", "40",
                "-pix_fmt", "yuv420p", "-color_range", "tv", "-color_primaries", "bt709",
                "-color_trc", "bt709", "-colorspace", "bt709", "-c:a", "aac", "-shortest"]
    audio = ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=9"]
    subprocess.run(base + ["-f", "lavfi", "-i",
        "color=red:s=160x96:r=20:d=3[r];color=lime:s=160x96:r=20:d=3[g];"
        "color=blue:s=160x96:r=20:d=3[b];[r][g][b]concat=n=3:v=1:a=0"] + audio + settings +
        [str(root / "red/red.mp4")], check=True, timeout=45)
    subprocess.run(base + ["-f", "lavfi", "-i", "color=blue:s=160x96:r=20:d=9"] + audio + settings +
        [str(root / "blue/blue.mp4")], check=True, timeout=45)
    subprocess.run(base + ["-f", "lavfi", "-i", "color=red:s=160x96:r=20:d=3",
        "-f", "lavfi", "-i", "sine=frequency=330:sample_rate=48000:duration=4.5",
        "-vf", "setpts=PTS+1.5/TB", "-fps_mode", "passthrough"] + settings +
        [str(root / "delayed/delayed.mp4")], check=True, timeout=45)
    subtitle = root / "compat/subtitle.srt"
    subtitle.write_text("1\n00:00:00,000 --> 00:00:08,500\nSynthetic compatibility fixture\n", encoding="utf-8")
    subprocess.run(base + ["-i", str(root / "red/red.mp4"), "-i", str(subtitle), "-map", "0:v",
        "-map", "0:a", "-map", "1:s", "-c:v", "copy", "-c:a", "copy", "-c:s", "mov_text",
        str(root / "compat/compat.mp4")], check=True, timeout=45)
    (root / "native-app-fixture.json").write_text(json.dumps({
        "format": 1, "run_id": run_id,
        "fixtures": ["red/red.mp4", "blue/blue.mp4", "compat/compat.mp4", "delayed/delayed.mp4"],
        "pixel_references": {
            "red": pixel_reference(ffmpeg, root / "red/red.mp4", 0.4),
            "green": pixel_reference(ffmpeg, root / "red/red.mp4", 4.2),
            "blue": pixel_reference(ffmpeg, root / "blue/blue.mp4", 0.4),
            "delayed_red": pixel_reference(ffmpeg, root / "delayed/delayed.mp4", 1.7),
        },
    }) + "\n", encoding="utf-8")


def make_queue_fixtures(source, destination, run_id):
    """Copy only known synthetic fixtures, never a preceding result or logs."""
    marker = json.loads((source / "native-app-fixture.json").read_text())
    destination.mkdir()
    for name in marker["fixtures"]:
        path = Path(name)
        if path.parts not in (("red", "red.mp4"), ("blue", "blue.mp4"),
                              ("compat", "compat.mp4"), ("delayed", "delayed.mp4")):
            raise RuntimeError("Unexpected generated fixture name.")
        original = source / path
        if original.is_symlink() or not original.is_file():
            raise RuntimeError("A generated fixture is no longer regular.")
        target = destination / path
        target.parent.mkdir(exist_ok=True)
        shutil.copyfile(original, target)
    marker.update(run_id=run_id, scenario="queue")
    (destination / "native-app-fixture.json").write_text(json.dumps(marker) + "\n", encoding="utf-8")


def run_queue_scenario(executable, *, workspace, environment, fixtures, report, build_id,
                       shared_identity_groups=None, shared_identity_expected=None):
    queue_id = str(uuid.uuid4())
    queue_report = report / "queue"
    queue_report.mkdir(exist_ok=False)
    queue_fixtures = workspace / "queue-fixtures"
    summary = {"format": 1, "run_id": queue_id, "scenario": "queue", "passed": False}
    try:
        make_queue_fixtures(fixtures, queue_fixtures, queue_id)
        groups = dict(shared_identity_groups or {}, fixtures=[queue_fixtures / name for name in
            ("red/red.mp4", "blue/blue.mp4", "compat/compat.mp4", "delayed/delayed.mp4", "native-app-fixture.json")])
        expected = snapshot_identity(groups, queue_report)
        if shared_identity_groups:
            for name in shared_identity_groups:
                if expected[name] != shared_identity_expected[name]:
                    raise RuntimeError("The queue process would use a different source or application build.")
        queue_environment = dict(environment, CHENGYING_NATIVE_APP_TEST_ROOT=str(queue_fixtures),
            CHENGYING_NATIVE_APP_TEST_RUN_ID=queue_id, CHENGYING_NATIVE_APP_TEST_BUILD_ID=build_id,
            CHENGYING_NATIVE_APP_TEST_SCENARIO="queue")
        with (queue_report / "app.log").open("wb") as log:
            result, data = run_application([str(executable), "--no-stdin"], workspace=workspace,
                environment=queue_environment, log=log, fixtures=queue_fixtures, report=queue_report,
                run_id=queue_id, required_checks=QUEUE_REQUIRED_CHECKS,
                identity_groups=groups, identity_expected=expected)
        summary["app_exit_code"] = result.returncode
        if data is None:
            raise RuntimeError("The queue App process produced no test result.")
        summary["checks"] = validate_result(data, run_id=queue_id, exit_code=result.returncode,
                                            required_checks=QUEUE_REQUIRED_CHECKS)
        summary["passed"] = True
        return summary
    finally:
        (queue_report / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")


def make_resume_fixtures(source, destination, writer_id, reader_id):
    make_queue_fixtures(source, destination, writer_id)
    marker_path = destination / "native-app-fixture.json"
    marker = json.loads(marker_path.read_text())
    marker.update(scenario="resume", resume_verify_run_id=reader_id)
    marker_path.write_text(json.dumps(marker) + "\n", encoding="utf-8")
    (destination / "watch-later").mkdir(mode=0o700)


def run_resume_scenarios(executable, *, workspace, environment, fixtures, report, build_id,
                         shared_identity_groups=None, shared_identity_expected=None):
    writer_id, reader_id = str(uuid.uuid4()), str(uuid.uuid4())
    resume_fixtures = workspace / "resume-fixtures"
    make_resume_fixtures(fixtures, resume_fixtures, writer_id, reader_id)
    summaries = {}
    fixture_identity = None
    for scenario, identifier, required, filename in (
            ("resume", writer_id, RESUME_REQUIRED_CHECKS, "result.json"),
            ("resume-verify", reader_id, RESUME_VERIFY_REQUIRED_CHECKS, "result-resume-verify.json")):
        current_report = report / scenario
        current_report.mkdir(exist_ok=False)
        summary = {"format": 1, "run_id": identifier, "scenario": scenario, "passed": False}
        try:
            # The two processes intentionally share exact media paths so MPV's
            # filename digest remains stable. Mutable watch-later state is not a fixture.
            groups = dict(shared_identity_groups or {}, fixtures=[resume_fixtures / name for name in
                ("red/red.mp4", "blue/blue.mp4", "compat/compat.mp4", "delayed/delayed.mp4", "native-app-fixture.json")])
            expected = snapshot_identity(groups, current_report)
            if fixture_identity is not None and expected["fixtures"] != fixture_identity:
                raise RuntimeError("Resume media or marker identity changed between processes.")
            fixture_identity = expected["fixtures"]
            if shared_identity_groups:
                for name in shared_identity_groups:
                    if expected[name] != shared_identity_expected[name]:
                        raise RuntimeError("The resume process would use a different source or application build.")
            current_environment = dict(environment, CHENGYING_NATIVE_APP_TEST_ROOT=str(resume_fixtures),
                CHENGYING_NATIVE_APP_TEST_RUN_ID=identifier, CHENGYING_NATIVE_APP_TEST_BUILD_ID=build_id,
                CHENGYING_NATIVE_APP_TEST_SCENARIO=scenario)
            with (current_report / "app.log").open("wb") as log:
                result, data = run_application([str(executable), "--no-stdin"], workspace=workspace,
                    environment=current_environment, log=log, fixtures=resume_fixtures, report=current_report,
                    run_id=identifier, required_checks=required, result_filename=filename,
                    identity_groups=groups, identity_expected=expected)
            summary["app_exit_code"] = result.returncode
            if data is None:
                raise RuntimeError("The resume App process produced no test result.")
            summary["checks"] = validate_result(data, run_id=identifier, exit_code=result.returncode,
                                                required_checks=required)
            summary["passed"] = True
            summaries[scenario] = summary
        finally:
            (current_report / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summaries


def cleanup_resume_preferences(bundle_id, report):
    if not re.fullmatch(r"io\.chengying\.tests\.native-app\.[0-9a-f]{32}", bundle_id):
        raise ValueError("Only the current disposable application domain can be removed.")
    source = r'''
import Foundation
guard CommandLine.arguments.count == 2, let defaults = UserDefaults(suiteName: CommandLine.arguments[1]) else { exit(1) }
let domain = CommandLine.arguments[1]
defaults.removePersistentDomain(forName: domain)
_ = defaults.synchronize()
guard defaults.persistentDomain(forName: domain)?.isEmpty != false else { exit(1) }
print("NATIVE_APP_TEST_PREFERENCES_CLEANED")
'''
    result = subprocess.run(["/usr/bin/xcrun", "swift", "-e", source, bundle_id],
                            capture_output=True, text=True, timeout=60)
    passed = result.returncode == 0 and result.stdout.strip() == "NATIVE_APP_TEST_PREFERENCES_CLEANED"
    (report / "resume-preferences-cleanup.json").write_text(json.dumps({
        "passed": passed, "exit_code": result.returncode}) + "\n")
    if not passed:
        raise RuntimeError("Disposable resume preference cleanup was not confirmed.")


def build_command(workspace, source_packages, bundle_id):
    return ["xcodebuild", "-project", str(ROOT / "iina.xcodeproj"), "-scheme", "iina",
            "-configuration", "Release", "-derivedDataPath", str(workspace / "DerivedData"),
            "-clonedSourcePackagesDirPath", str(source_packages), "ONLY_ACTIVE_ARCH=YES", "ARCHS=arm64",
            "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=",
            "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES",
            f"PRODUCT_BUNDLE_IDENTIFIER={bundle_id}",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CHENGYING_NATIVE_APP_TESTS"]


@contextmanager
def owned_application_workspace(summary):
    owner = None
    try:
        owner = TestAppWorkspace(prefix="native-full-app-")
        with owner as path:
            yield Path(path)
    finally:
        # A failed assertion does not imply failed cleanup, and completed
        # cleanup must never turn that assertion into a passing App result.
        summary["cleanup"] = ("not_started" if owner is None else
                              "completed" if owner.cleaned else "unconfirmed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-packages", type=Path, required=True)
    parser.add_argument("--report-directory", type=Path, required=True)
    parser.add_argument("--production-app", type=Path, required=True)
    parser.add_argument("--include-queue", action="store_true", help="Also run the independent native queue process.")
    parser.add_argument("--include-resume", action="store_true", help="Also run independent resume write/readback processes.")
    args = parser.parse_args()
    environment = dict(os.environ)
    validate_environment(environment)
    source_packages = args.source_packages.resolve(strict=True)
    report = args.report_directory.resolve()
    report.mkdir(parents=True, exist_ok=False)
    run_id = str(uuid.uuid4())
    bundle_id = "io.chengying.tests.native-app." + run_id.replace("-", "")
    summary = {"format": 1, "run_id": run_id, "passed": False, "cleanup": "not_started"}
    try:
        source_groups = {"source": [ROOT / "iina", ROOT / "Configs", ROOT / "deps/include",
            ROOT / "iina.xcodeproj/project.pbxproj", ROOT / "iina.xcodeproj/xcshareddata",
            Path(__file__).resolve(), ROOT / "Tools/NativeAppTests/NativeAppTestDriver.swift",
            ROOT / "other/test_app_workspace.py", ROOT / "other/embed_download_center.sh"]}
        source_expected = snapshot_identity(source_groups, report)
        production = args.production_app.resolve(strict=True)
        production_info = plistlib.loads((production / "Contents/Info.plist").read_bytes())
        if production_info.get("CFBundleIdentifier") != "io.github.SeanLi-Coder.ChengYingPlayer":
            raise RuntimeError("The regular build changed its production application identity.")
        release_strings = subprocess.check_output(["/usr/bin/strings", "-a",
            str(production / "Contents/MacOS/ChengYing")], timeout=30)
        if b"NATIVE_APP_TEST_" in release_strings or b"CHENGYING_NATIVE_APP_TEST_ROOT" in release_strings:
            raise RuntimeError("The CI-only driver was unexpectedly compiled into the regular App.")
        summary["regular_build_excludes_test_driver"] = True
        with owned_application_workspace(summary) as workspace:
            fixtures = workspace / "fixtures"
            fixtures.mkdir()
            make_fixtures(fixtures, run_id)
            with (report / "build.log").open("wb") as log:
                subprocess.run(build_command(workspace, source_packages, bundle_id), cwd=ROOT,
                               env=environment, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=900)
            verify_identity(source_groups, source_expected, report, stage="after-build")
            app = workspace / "DerivedData/Build/Products/Release/ChengYing.app"
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            if info.get("CFBundleIdentifier") != bundle_id:
                raise RuntimeError("The test build did not use its isolated application identity.")
            executable = app / "Contents/MacOS/ChengYing"
            if not executable.is_file() or executable.is_symlink():
                raise RuntimeError("The expected test executable is missing.")
            shared_groups = dict(source_groups, product=[app])
            shared_expected = dict(source_expected, **snapshot_identity({"product": [app]}, report))
            fixture_groups = {"fixtures": [fixtures / name for name in
                ("red/red.mp4", "blue/blue.mp4", "compat/compat.mp4", "delayed/delayed.mp4", "native-app-fixture.json")]}
            groups = dict(shared_groups, **fixture_groups)
            expected = dict(shared_expected, **snapshot_identity(fixture_groups, report))
            environment.update({"CHENGYING_NATIVE_PLAYBACK": "1", "NSUnbufferedIO": "YES",
                "CHENGYING_NATIVE_APP_TEST_ROOT": str(fixtures), "CHENGYING_NATIVE_APP_TEST_RUN_ID": run_id,
                "CHENGYING_NATIVE_APP_TEST_BUILD_ID": run_id, "CHENGYING_NATIVE_APP_TEST_SCENARIO": "baseline"})
            with (report / "app.log").open("wb") as log:
                result, result_data = run_application([str(executable), "--no-stdin"], workspace=workspace,
                    environment=environment, log=log, fixtures=fixtures, report=report, run_id=run_id,
                    identity_groups=groups, identity_expected=expected)
            if result_data is None:
                raise RuntimeError("The complete App produced no test result.")
            summary["app_exit_code"] = result.returncode
            summary["checks"] = validate_result(result_data, run_id=run_id, exit_code=result.returncode)
            if args.include_queue:
                summary["queue"] = run_queue_scenario(executable, workspace=workspace, environment=environment,
                    fixtures=fixtures, report=report, build_id=run_id,
                    shared_identity_groups=shared_groups, shared_identity_expected=shared_expected)
            if args.include_resume:
                summary["resume"] = run_resume_scenarios(executable, workspace=workspace, environment=environment,
                    fixtures=fixtures, report=report, build_id=run_id,
                    shared_identity_groups=shared_groups, shared_identity_expected=shared_expected)
        if summary["cleanup"] != "completed":
            raise RuntimeError("Owned application workspace cleanup was not confirmed.")
        if args.include_resume:
            cleanup_resume_preferences(bundle_id, report)
            summary["resume_preference_cleanup"] = "completed"
        summary["passed"] = True
        print("PASS: Complete native App test and owned workspace cleanup", flush=True)
    finally:
        try:
            if args.include_resume and summary.get("resume_preference_cleanup") != "completed":
                cleanup_resume_preferences(bundle_id, report)
                summary["resume_preference_cleanup"] = "completed"
        except BaseException:
            summary["passed"] = False
            summary["resume_preference_cleanup"] = "unconfirmed"
            raise
        finally:
            (report / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()
