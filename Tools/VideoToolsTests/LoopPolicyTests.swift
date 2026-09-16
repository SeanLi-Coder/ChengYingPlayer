import Foundation

func runVideoToolsLoopTests() {
  let range = VideoToolsLoopRange(start: 0, end: 5, duration: 120)!
  check(range.start == 0 && range.contains(0), "A zero is a valid loop endpoint")
  check(!range.contains(5) && !range.contains(-1), "Loop interval excludes B and positions before A")
  check(range.clamped(-100) == 0 && range.clamped(100) < 5, "Seek clamps both directions inside the loop")
  check(range.clamped(.nan) == 0 && range.clamped(.infinity) == 0, "Non-finite seek targets cannot escape the range")
  check(VideoToolsLoopRange(start: nil, end: 5) == nil, "A missing A marker cannot activate looping")
  check(VideoToolsLoopRange(start: 5, end: 5) == nil && VideoToolsLoopRange(start: 5, end: 4) == nil, "Equal or reversed markers are invalid")
  check(VideoToolsLoopRange(start: .nan, end: 5) == nil && VideoToolsLoopRange(start: 0, end: .infinity) == nil, "Non-finite loop endpoints are invalid")
  check(VideoToolsLoopRange(start: 0, end: 121, duration: 120) == nil, "Loop endpoints cannot pass the media duration")
  let tiny = VideoToolsLoopRange(start: 10, end: 10.0001)!
  check(tiny.contains(tiny.lastSeekPosition), "Sub-millisecond loop clamps to its interior")
  let eofRange = VideoToolsLoopRange(start: 100, end: 120, duration: 120)!
  check(eofRange.clamped(120) < 120, "EOF seeks stop before the loop end")
  check(VideoToolsLoopRange.marker(from: "0.000000") == 0 && VideoToolsLoopRange.marker(from: "no") == nil, "Zero and disabled mpv marker values stay distinct")

  var recovery = VideoToolsLoopRecovery()
  recovery.userSeek(to: 2)
  recovery.userSeek(to: range.clamped(recovery.pendingTarget! + 1))
  check(recovery.pendingTarget == 3, "Rapid relative seeks accumulate from the pending destination")
  check(!recovery.beginCorrection(to: 0), "A pending seek suppresses duplicate correction commands")
  recovery.didRestart()
  for _ in 0..<3 {
    check(recovery.beginCorrection(to: 0), "A failed decoder restart receives a bounded recovery seek")
    recovery.didRestart()
  }
  check(!recovery.beginCorrection(to: 0) && recovery.suspended, "Repeated decode failures suspend recovery instead of seek spinning")
  recovery.userSeek(to: 1)
  check(!recovery.suspended && recovery.failures == 0, "An explicit seek resets suspended loop recovery")
  recovery.reachedRange()
  check(recovery.pendingTarget == nil && recovery.failures == 0, "Valid playback resets the correction budget")

  let loopPlayer = PlayerCore()
  loopPlayer.info.currentURL = URL(fileURLWithPath: "/tmp/chengying-loop-tests.mp4")
  loopPlayer.videoToolsClearLoop()
  loopPlayer.mpv.values["time"] = 3.0
  check(!loopPlayer.videoToolsSetLoopEnd(), "Setting B before A is rejected by the production bridge")
  loopPlayer.mpv.values["time"] = 0.0
  check(loopPlayer.videoToolsSetLoopStart(), "The production bridge accepts A at video start")
  check(!loopPlayer.videoToolsSetLoopEnd(), "The production bridge rejects B equal to A")
  loopPlayer.mpv.values["time"] = 5.0
  check(loopPlayer.videoToolsSetLoopEnd() && loopPlayer.videoToolsLoopRange == range, "Setting valid B activates the exact zero-start range")
  check(loopPlayer.mpv.getDouble("time") == 0, "Setting B seeks directly back to A")
  let snapshot = loopPlayer.videoToolsCaptureSnapshot()!
  loopPlayer.videoToolsPreviewRange(start: 10, end: 20)
  loopPlayer.videoToolsRestoreSnapshot(snapshot)
  check(loopPlayer.videoToolsLoopRange == range, "Preview restoration preserves an original loop with A zero")
  loopPlayer.mpv.values["time"] = 2.0
  check(loopPlayer.videoToolsSetLoopStart() && loopPlayer.videoToolsLoopRange == nil, "Replacing A clears old B and disables the previous loop")
  loopPlayer.mpv.values["time"] = 1.0
  check(!loopPlayer.videoToolsSetLoopEnd(), "The production bridge rejects B before A")
  loopPlayer.mpv.values["time"] = Double.nan
  check(!loopPlayer.videoToolsSetLoopStart() && !loopPlayer.videoToolsSetLoopEnd(), "Non-finite decoder positions cannot set markers")
  loopPlayer.videoToolsMediaGeneration += 1
  loopPlayer.mpv.values["time"] = 80.0
  loopPlayer.videoToolsRestoreSnapshot(snapshot)
  check(loopPlayer.videoToolsLoopRange == nil && loopPlayer.mpv.getDouble("time") == 80, "Stale loop snapshots cannot restore into another media generation")
  loopPlayer.videoToolsClearLoop()
  check(loopPlayer.mpv.getString("a") == "no" && loopPlayer.mpv.getString("b") == "no", "Clearing a loop unsets markers without rewriting A zero")
  loopPlayer.mpv.values["eof"] = true
  check(!loopPlayer.videoToolsSetLoopStart(), "A cannot be set at EOF with no playable interval afterward")
}
