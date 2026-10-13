#!/usr/bin/env python3
"""Exercise extracted production seek policy without AppKit windows or user media."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def section(source, start, end):
    if source.count(start) != 1:
        raise RuntimeError(f"Production extraction boundary changed: {start}")
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


def method(source, signature):
    start = f"  func {signature}"
    return section(source, start, "\n  }") + "\n  }"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--parent-ref", help="Require the previous production relative-seek method to fail")
    parser.add_argument("--live", action="store_true", help="Also check synthetic media with real libmpv and vo=null")
    parser.add_argument("--deps-dir", type=Path, default=ROOT / "deps")
    args = parser.parse_args()
    if args.live and args.parent_ref:
        parser.error("The previous-method negative control and current live integration must run separately")
    source = (ROOT / "iina/MPVController.swift").read_text()
    core = (ROOT / "iina/PlayerCore.swift").read_text()
    old_core = subprocess.check_output(["git", "show", f"{args.parent_ref}:iina/PlayerCore.swift"],
                                      cwd=ROOT, text=True, timeout=30) if args.parent_ref else core
    timing = section(source, "struct MPVSeekTiming {", "\n/// Change this variable")
    members = section(source, "  @Atomic private var seekTimingToken:", "  // MARK: - End auto seek timing")
    members = members.replace("private ", "")
    generated = "import Foundation\nimport QuartzCore\n" + timing + "\n" + """
final class TimingController {
  let player = TimingPlayer()
  var seeking = false
  var flagReader: ((String) -> Bool)?
  func getFlag(_ name: String) -> Bool { flagReader?(name) ?? seeking }
""" + members + "\n}\n" + """
final class SeekCore {
  let isUsingNativePlayback = false
  func recordNativeQueueSeek(_ result: PlaybackTransportResult) {
    precondition(!isUsingNativePlayback, "No native queue in MPV timing tests")
  }
  let hasPendingPermanentRotation = false
  struct RotationRestoreBoundary { let position: Double }
  var pendingRotationPlaybackRestore: RotationRestoreBoundary? {
    precondition(!hasPendingPermanentRotation)
    return nil
  }
  @discardableResult
  func updatePendingRotationRestore(paused: Bool? = nil, position: Double? = nil) -> Bool {
    precondition(pendingRotationPlaybackRestore == nil)
    return false
  }
  @discardableResult
  func cancelPendingPermanentRotation(requestID: UUID? = nil) -> Bool {
    precondition(!hasPendingPermanentRotation)
    return false
  }
  func cancelNativePreview(restoreLoop: Bool) {
    preconditionFailure("Unexpected native preview in MPV timing tests")
  }
  func cancelNativeLoopRequests() {
    preconditionFailure("Unexpected native seek in MPV timing tests")
  }
  var triedUsingExactSeekForCurrentFile = false
  var useExactSeekForCurrentFile = true
  var videoToolsMediaGeneration: UInt64 = 1
  var videoToolsLoopRange: VideoToolsLoopRange?
  var videoToolsLoopRecovery = VideoToolsLoopRecovery()
  var videoToolsCurrentTime: Double? = 0
  var absoluteTarget: Double?
  let mpv = SeekCommandBoundary()
  lazy var playbackTransport: PlaybackTransport = MPVPlaybackTransport(sink: .init(
    isAvailable: { true }, getFlag: { _ in false }, getDouble: { _ in 0 },
    setFlag: { _, _, _ in }, setDouble: { _, _, _ in },
    command: { [weak self] name, arguments, context in
      self?.mpv.command(MPVCommand(name), args: arguments.map(Optional.some),
        checkError: context.checkError, level: context.verbosity == .verbose ? .verbose : .debug,
        seekTimingGeneration: context.seekTimingGeneration)
    }))
  func seek(absoluteSecond: Double) { absoluteTarget = absoluteSecond }
""" + method(old_core, "seek(relativeSecond: Double, option: Preference.SeekOption)") + "\n" + method(core, "resetAutoSeekForNewMedia()") + "\n}\n"
    # Fail if lifecycle wiring ceases to invalidate before dispatching UI work.
    for event in ("SHUTDOWN", "START_FILE", "END_FILE", "QUEUE_OVERFLOW"):
        if f"case MPV_EVENT_{event}:\n      cancelSeekTiming()" not in source:
            raise RuntimeError(f"Missing lifecycle invalidation: {event}")
    if "resetAutoSeekForNewMedia()" not in section(core, "  func fileLoaded()", "  func fileEnded("):
        raise RuntimeError("New files must reset both automatic-seek flags")
    if "private(set) var videoToolsMediaGeneration: UInt64" not in core:
        raise RuntimeError("The test boundary must match the production media-generation type")
    for event, clock_name, action in [("SEEK", "seekTime", "observeSeekTiming"),
                                      ("PLAYBACK_RESTART", "restartTime", "finishSeekTiming")]:
        block = section(source, f"    case MPV_EVENT_{event}:", "\n    case ")
        if block.index(f"let {clock_name} = CACurrentMediaTime()") > block.index("DispatchQueue.main.async"):
            raise RuntimeError("Seek timestamps must be captured before main-queue dispatch")
        if f"{action}(token: timingToken, at: {clock_name})" not in block:
            raise RuntimeError("The event must deliver its captured timing values unchanged")
    restart = section(source, "    case MPV_EVENT_PLAYBACK_RESTART:", "\n    case ")
    if "markSeekTimingPlaybackReady(token: timingToken)" not in restart:
        raise RuntimeError("Only the captured restart generation may restore readiness")
    with tempfile.TemporaryDirectory(prefix="chengying-seek-timing-") as directory:
        work = Path(directory)
        extracted = work / "Production.swift"
        extracted.write_text(generated)
        executable = work / "SeekTimingTests"
        sources = [ROOT / "iina/Atomic.swift", ROOT / "iina/Lock.swift", ROOT / "iina/MPVCommand.swift",
                   ROOT / "iina/PlaybackBackend/PlaybackTransport.swift",
                   ROOT / "iina/PlaybackBackend/MPVPlaybackTransport.swift",
                   ROOT / "iina/VideoTools/VideoToolsLoopPolicy.swift",
                   ROOT / "Tools/SeekTimingTests/Boundary.swift", extracted,
                   ROOT / "Tools/SeekTimingTests/main.swift"]
        subprocess.run(["xcrun", "swiftc", "-o", str(executable), *map(str, sources)], check=True, timeout=90)
        result = subprocess.run([str(executable)] + (["--parent-control"] if args.parent_ref else []),
                                capture_output=True, text=True, timeout=15)
        print(result.stdout, end="")
        print(result.stderr, end="")
        if args.parent_ref:
            if result.returncode != 1 or "first automatic probe must measure an exact seek" not in result.stderr:
                raise RuntimeError("The previous method did not fail at the intended negative-control assertion")
            print("PASS: Previous production method failed at the expected exact-probe assertion")
        elif result.returncode:
            raise subprocess.CalledProcessError(result.returncode, str(executable))
        if args.live:
            run_live(work, sources[:-1], args.deps_dir.resolve())


def run_live(work, sources, deps):
    library = deps / "lib/libmpv.2.dylib"
    if not library.is_file() or not (deps / "include/mpv/client.h").is_file():
        raise RuntimeError("The selected playback dependencies must contain libmpv and its public header")
    print(f"LIBMPV_SHA256: {hashlib.sha256(library.read_bytes()).hexdigest()}", flush=True)
    record = deps / "playback-build-record/patches.tsv"
    if record.is_file():
        print("PATCH_IDS: " + ", ".join(line.split("\t")[0] for line in record.read_text().splitlines()), flush=True)
    media = work / "synthetic-motion.mp4"
    subprocess.run([str(ROOT / "deps/executable/ffmpeg"), "-nostdin", "-hide_banner", "-loglevel", "error",
                    "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-t", "6", "-c:v", "libx264",
                    "-preset", "ultrafast", "-g", "90", "-pix_fmt", "yuv420p", str(media)],
                   check=True, timeout=30)
    header = work / "Bridge.h"
    header.write_text("#include <mpv/client.h>\n")
    live_directory = work / "live"
    live_directory.mkdir()
    live_main = live_directory / "main.swift"
    live_main.write_bytes((ROOT / "Tools/SeekTimingTests/live.swift").read_bytes())
    executable = work / "SeekTimingLiveTests"
    subprocess.run(["xcrun", "swiftc", "-o", str(executable), *map(str, sources), str(live_main),
                    "-import-objc-header", str(header), "-I", str(deps / "include"), str(library),
                    "-Xlinker", "-rpath", "-Xlinker", str(deps / "lib")], check=True, timeout=90)
    subprocess.run([str(executable), str(media)], check=True, timeout=30)


if __name__ == "__main__":
    main()
