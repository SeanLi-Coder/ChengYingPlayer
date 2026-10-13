"""Exercise the exact production preroll completion method without renderers."""
from pathlib import Path
import hashlib
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "iina/NativePlayback/NativePlaybackSession.swift"


def extract(source):
    start = "  private func finishPrerollIfReady() -> Bool {"
    end = "  private func pump() {"
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError("Production preroll boundaries are not unique")
    method, separator, _ = source.split(start, 1)[1].partition(end)
    if not separator or not method.rstrip().endswith("}"):
        raise ValueError("Production preroll method boundary changed")
    return (start + method).replace("  private func", "  func", 1)


PREFIX = r'''
import Foundation
struct ClockTime { var seconds: Double = 0 }
final class Output {
  var currentTime = ClockTime()
  var actualRate: Float = 0
  var ready = true
  func isReady(video: Bool) -> Bool { ready }
  func setRate(_ value: Float) { actualRate = value }
}
enum Phase { case seeking, playing, paused }
struct Held { var start: Double }
final class Harness {
  var preroll = true
  var prerollSamples = 1
  var wantsPlayback = false
  var hasVideo = true
  var hasAudio = false
  var eof = false
  var prerollBackpressure = false
  var prerollStarted = ProcessInfo.processInfo.systemUptime - 1
  var lowerBound = 0.0
  var maximumLead = 0.5
  var heldPrerollAudioHead = 0
  var heldPrerollAudio: [Held?] = [Held(start: 0)]
  var phase = Phase.seeking
  var rate: Float = 1
  var output = Output()
  func publish(force: Bool) {}
'''
SUFFIX = r'''
}
var passed = 0
var failed = 0
func check(_ condition: Bool, _ label: String) {
  if condition { passed += 1; print("PASS: " + label) }
  else { failed += 1; print("FAIL: " + label) }
}
let ready = Harness()
check(!ready.finishPrerollIfReady() && ready.phase == .seeking,
      "First ready held audio gets a bounded drain opportunity")
let backpressureHistory = Harness()
backpressureHistory.prerollBackpressure = true
check(!backpressureHistory.finishPrerollIfReady(),
      "Past backpressure does not discard currently ready first audio")
let stillBlocked = Harness()
stillBlocked.output.ready = false
check(stillBlocked.finishPrerollIfReady() && stillBlocked.phase == .paused,
      "Currently blocked audio does not deadlock a paused preview")
let future = Harness()
future.heldPrerollAudio = [Held(start: 0.500001)]
check(future.finishPrerollIfReady(),
      "Future audio outside the lead budget does not deadlock a paused clock")
let oneSubmitted = Harness()
oneSubmitted.hasAudio = true
check(oneSubmitted.finishPrerollIfReady(),
      "Already submitted audio does not force a full FIFO drain")
let autoplay = Harness()
autoplay.wantsPlayback = true
check(autoplay.finishPrerollIfReady() && autoplay.output.actualRate == 1,
      "Autoplay fallback gate remains unchanged")
let noHeld = Harness()
noHeld.heldPrerollAudio = []
check(noHeld.finishPrerollIfReady(), "Absent audio keeps the previous paused fallback")
let badClock = Harness()
badClock.hasAudio = true
badClock.output.currentTime.seconds = 1
check(!badClock.finishPrerollIfReady(), "Unanchored clock cannot finish preroll")
let noVideo = Harness()
noVideo.hasVideo = false
noVideo.hasAudio = true
check(!noVideo.finishPrerollIfReady(), "Paused preview still waits for actual video")
print("RESULT: \(passed) passed / \(failed) failed")
exit(failed == 0 ? 0 : 1)
'''


def main():
    before = SOURCE.read_bytes()
    method = extract(before.decode())
    # These parser negatives must fail instead of silently testing a different method.
    for text in (before.decode().replace("finishPrerollIfReady() -> Bool", "missing() -> Bool"),
                 before.decode() + "\n  private func finishPrerollIfReady() -> Bool {\n"):
        try:
            extract(text)
        except ValueError:
            pass
        else:
            raise AssertionError("Ambiguous production method was accepted")
    directory = Path(tempfile.mkdtemp(prefix="native-seek-gate.", dir=ROOT / "build"))
    generated = directory / "main.swift"
    generated.write_text(PREFIX + method + SUFFIX)
    binary = directory / "gate-tests"
    subprocess.run(["xcrun", "swiftc", str(generated), "-o", str(binary)], check=True)
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
    (directory / "results.log").write_text(result.stdout + result.stderr)
    print(result.stdout, end="")
    result.check_returncode()
    if SOURCE.read_bytes() != before:
        raise AssertionError("Production source changed during the test")
    (directory / "source.sha256").write_text(hashlib.sha256(before).hexdigest() + "  " + str(SOURCE) + "\n")
    print("Artifacts: " + str(directory))


if __name__ == "__main__":
    main()
