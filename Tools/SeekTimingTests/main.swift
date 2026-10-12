import Foundation
import QuartzCore

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
  checks += 1
}

let core = SeekCore()
core.useExactSeekForCurrentFile = false
core.seek(relativeSecond: 4, option: .auto)
check(core.mpv.commands.last?[1] == "relative+exact", "The first automatic probe must measure an exact seek, not the previous file's keyframe mode")
if CommandLine.arguments.contains("--parent-control") {
  fputs("FAIL: The previous production method unexpectedly passed its negative control\n", stderr)
  exit(2)
}
check(core.mpv.generations.last! == 1, "The first probe carries the current media generation")
core.resetAutoSeekForNewMedia()
check(!core.triedUsingExactSeekForCurrentFile && core.useExactSeekForCurrentFile, "New media resets both probe state and exact-seek policy")
core.useExactSeekForCurrentFile = false
core.triedUsingExactSeekForCurrentFile = true
core.seek(relativeSecond: 2, option: .auto)
check(core.mpv.commands.last?[1] == "relative" && core.mpv.generations.last! == nil, "A valid slow sample changes later automatic seeks without probing again")
core.seek(relativeSecond: 3, option: .exact)
check(core.mpv.commands.last?[1] == "relative+exact", "Explicit exact mode stays exact")
core.seek(relativeSecond: -2, option: .relative)
check(core.mpv.commands.last?[1] == "relative", "Explicit keyframe mode stays unchanged")
let before = core.mpv.commands.count
core.seek(relativeSecond: .nan, option: .auto)
check(core.mpv.commands.count == before, "Nonfinite input does not submit a seek")
core.videoToolsLoopRange = VideoToolsLoopRange(start: 2, end: 8)
core.videoToolsCurrentTime = 7
core.seek(relativeSecond: 10, option: .auto)
check(core.absoluteTarget == 17 && core.mpv.commands.count == before, "The existing A-B absolute-seek routing is preserved")

var state = MPVSeekTiming()
state.arm(token: 1, mediaGeneration: 4, at: 0)
state.seek(token: 1, at: 0.01)
let sample = state.restart(token: 1, at: 0.03)
check(abs(sample!.interval - 0.02) < 0.000001 && sample?.mediaGeneration == 4, "Only event-observation timestamps define the sample")
check(!state.isArmed && state.restart(token: 1, at: 0.04) == nil, "A sample can complete only once")
state.arm(token: 2, mediaGeneration: 4, at: 10)
state.seek(token: 1, at: 11)
check(state.restart(token: 2, at: 11.1) == nil, "An old token cannot supply the seek start")
state.arm(token: 3, mediaGeneration: 4, at: 20)
state.seek(token: 3, at: 20.1)
state.seek(token: 3, at: 20.2)
check(state.restart(token: 3, at: 20.3) == nil, "Overlapping seeks discard the ambiguous sample")
state.arm(token: 4, mediaGeneration: 4, at: 30)
state.seek(token: 4, at: 29)
check(!state.isArmed, "Events observed before arming cannot be attributed to the probe")
state.arm(token: 5, mediaGeneration: 4, at: 40)
state.seek(token: 5, at: 40.1)
check(state.restart(token: 5, at: 46) == nil && !state.isArmed, "An expired seek never updates the policy")
state.arm(token: 6, mediaGeneration: 4, at: 50)
state.seek(token: 6, at: .nan)
check(!state.isArmed, "Nonfinite timing is rejected")

let controller = TimingController()
controller.beginSeekTiming(mediaGeneration: 1)
check(!controller.seekTiming.isArmed, "The initial playback restart is required before probing")
controller.markSeekTimingPlaybackReady(token: controller.seekTimingToken)
controller.seeking = true
controller.beginSeekTiming(mediaGeneration: 1)
check(!controller.seekTiming.isArmed, "Already-seeking media cannot start a timing probe")
controller.seeking = false
controller.markSeekTimingPlaybackReady(token: controller.seekTimingToken)
controller.beginSeekTiming(mediaGeneration: 1)
let token = controller.seekTimingToken
let timestamp = CACurrentMediaTime()
controller.observeSeekTiming(token: token, at: timestamp)
// These calls model delayed main-queue delivery using timestamps captured earlier.
// The old main-queue measurement could inflate 10 ms into 200 ms or compress 200 ms to zero.
let oldMainQueueInterval = 0.20
controller.finishSeekTiming(token: token, at: timestamp + 0.01)
check(oldMainQueueInterval >= 0.05 && controller.player.useExactSeekForCurrentFile, "Main-queue delivery delay cannot turn a fast sample into a slow one")
controller.markSeekTimingPlaybackReady(token: controller.seekTimingToken)
controller.beginSeekTiming(mediaGeneration: 1)
let slowToken = controller.seekTimingToken
let slowStart = CACurrentMediaTime()
controller.observeSeekTiming(token: slowToken, at: slowStart)
controller.finishSeekTiming(token: slowToken, at: slowStart + 0.20)
check(!controller.player.useExactSeekForCurrentFile, "Batched main-queue delivery cannot turn a slow sample into a fast one")
controller.player.useExactSeekForCurrentFile = true
controller.markSeekTimingPlaybackReady(token: controller.seekTimingToken)
controller.beginSeekTiming(mediaGeneration: 1)
let oldToken = controller.seekTimingToken
controller.observeSeekTiming(token: oldToken, at: CACurrentMediaTime())
controller.cancelSeekTiming()
controller.finishSeekTiming(token: oldToken, at: CACurrentMediaTime() + 0.20)
check(controller.player.useExactSeekForCurrentFile, "Cancellation invalidates an already queued completion")
controller.markSeekTimingPlaybackReady(token: oldToken)
controller.beginSeekTiming(mediaGeneration: 1)
check(!controller.seekTiming.isArmed, "An old queued restart cannot restore readiness after cancellation")
let readyToken = controller.seekTimingToken
controller.markSeekTimingPlaybackReady(token: readyToken)
controller.cancelSeekTiming()
controller.beginSeekTiming(mediaGeneration: 1)
check(!controller.seekTiming.isArmed, "A synchronous slider seek with undelivered events invalidates earlier readiness")
controller.markSeekTimingPlaybackReady(token: readyToken)
check(controller.seekTimingReadyToken != controller.seekTimingToken, "A stale restart cannot re-enable a newer seek generation")
controller.markSeekTimingPlaybackReady(token: controller.seekTimingToken)
controller.beginSeekTiming(mediaGeneration: 1)
check(controller.seekTiming.isArmed, "The current generation's completed restart permits a new exact probe")
let replacedToken = controller.seekTimingToken
controller.observeSeekTiming(token: replacedToken, at: CACurrentMediaTime())
controller.player.videoToolsMediaGeneration = 2
controller.finishSeekTiming(token: replacedToken, at: CACurrentMediaTime() + 0.20)
check(controller.player.useExactSeekForCurrentFile, "An old media generation cannot alter the new file's policy")
controller.cancelSeekTiming()
controller.player.info.state.loaded = false
controller.markSeekTimingPlaybackReady(token: controller.seekTimingToken)
check(controller.seekTimingReadyToken != controller.seekTimingToken, "Unloaded media cannot acquire readiness")
for name in ["seek", "stop", "quit", "loadfile", "loadlist", "frame-step", "frame-back-step", "playlist-next", "playlist-prev", "playlist-play-index"] {
  check(controller.commandInvalidatesSeekTiming(MPVCommand(name)), "Playback-disrupting commands invalidate the sample")
}
check(!controller.commandInvalidatesSeekTiming(.screenshot), "An unrelated screenshot command does not invalidate playback state")
print("PASS: Seek timing production regression completed: \(checks) checks")
