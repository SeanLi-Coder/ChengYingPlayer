import AppKit
import AVFoundation

var passes = 0, failures = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
  if condition() { passes += 1; print("PASS: \(name)") }
  else { failures += 1; print("FAIL: \(name)") }
}
var cores = [PlayerCore]()
// Sample output only on its real worker while the main run loop is held. The
// same 1.55-second budget replaces a fixed 0.55-second delay plus a 1-second
// query wait; it does not grant additional time or dispatch a synthetic EOF.
final class DelayedEOFProbe {
  let session: NativePlaybackSession
  let worker: DispatchQueue
  let deadline = DispatchTime.now() + 1.55
  let completed = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var observation = (ended: false, time: Double.nan, rate: Double.nan)
  init(session: NativePlaybackSession, worker: DispatchQueue) { self.session = session; self.worker = worker }
  func sample() {
    let rate = session.output.actualRate
    let time = CMTimeGetSeconds(session.output.currentTime)
    let ended = rate == 0 && time >= 4.99
    lock.lock(); observation = (ended, time, rate); lock.unlock()
    if ended || DispatchTime.now() >= deadline { completed.signal() }
    else { worker.asyncAfter(deadline: .now() + 0.005) { self.sample() } }
  }
  func read() -> (ended: Bool, time: Double, rate: Double) {
    lock.lock(); defer { lock.unlock() }; return observation
  }
}
@discardableResult
func wait(_ seconds: Double = 5, _ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  repeat {
    for core in cores { for _ in 0..<32 { core.mpv.pump() } }
    if condition() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
  } while Date() < deadline
  return condition()
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
fixtureDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let red = fixtureDirectory.appendingPathComponent("red.mp4")
let blue = fixtureDirectory.appendingPathComponent("blue.mp4")
let unsupported = fixtureDirectory.appendingPathComponent("multi-audio.mp4")
func makeCore(_ urls: [URL]) -> PlayerCore {
  let core = PlayerCore(); cores.append(core); PlayerCore.lastActive = core
  check(core.openMediaURLs(urls, shouldAutoLoad: false) == urls.count, "Explicit selection count remains intact")
  check(wait { core.isUsingNativePlayback && core.info.state == .paused }, "Real native queue reaches paused ready")
  return core
}
func close(_ core: PlayerCore) {
  core.stop()
  check(wait { !core.isUsingNativePlayback && core.nativeQueue == nil }, "Stop retires session and invalidates queue")
  core.mainWindow.videoView.uninit(); core.mainWindow.close()
}
Preference.pauseWhenOpen = true
let core = PlayerCore(); cores.append(core); PlayerCore.lastActive = core
check(core.openMediaURLs([red, blue, red], shouldAutoLoad: false) == 3, "Explicit duplicate queue is admitted")
check(wait { core.isUsingNativePlayback && core.info.state == .paused && core.info.playlist.count == 3 }, "First native queue item reaches paused readiness")
check(core.info.playlist.map(\.filename) == [red.path, blue.path, red.path], "Native projection preserves complete order and duplicates")
check(core.mpv.client.appendCalls == 0, "Native first item does not load idle MPV")
let identity = core.info.playlist.map(ObjectIdentifier.init)
core.navigateInPlaylist(nextMedia: true)
check(wait { core.nativeQueue?.selectedIndex == 1 && core.info.state == .paused && core.info.currentURL == blue }, "Typed next loads native second item")
check(core.info.playlist.map(ObjectIdentifier.init) == identity && core.playbackVolume == 0, "Native projection identity and silent-open policy survive next")
core.navigateInPlaylist(nextMedia: false)
check(wait { core.nativeQueue?.selectedIndex == 0 && core.info.state == .paused && core.info.currentURL == red }, "Typed previous returns to first native item")
core.playFileInPlaylist(2)
check(core.nativeRetiring && core.nativeQueueLoadPending, "Manual navigation exposes draining intent instead of old snapshot")
core.togglePause(); check(!core.playbackIsPaused, "First toggle updates draining queue intent")
core.togglePause(); check(core.playbackIsPaused, "Second toggle restores draining pause intent")
check(wait { core.nativeQueue?.selectedIndex == 2 && core.info.state == .paused && core.isUsingNativePlayback }, "Duplicate selection opens distinct native generation")
core.seek(absoluteSecond: 1.2)
check(wait { abs((core.playbackPosition ?? -1) - 1.2) < 0.05 && core.info.state == .paused }, "Selected native item accepts exact paused seek")
var completed = 0
var busyChecked = false
core.mpv.beforeRestart = {
  guard core.hasPendingNativeQueueRestore else { return }
  busyChecked = true
  let commands = core.mpv.client.commandNames
  let selected = core.mpv.queueSnapshot()?.entries.filter(\.current).first?.id
  core.navigateInPlaylist(nextMedia: false); core.playFileInPlaylist(0)
  core.appendToPlaylist(blue.path); core.addToPlaylist(paths: [blue.path])
  core.playlistMove(0, to: 2); core.playlistRemove(1); core.clearPlaylist(); core.toggleShuffle()
  check(core.mpv.client.commandNames == commands && core.mpv.queueSnapshot()?.entries.filter(\.current).first?.id == selected,
        "Restore rejects navigation and every tested mutable-list command before ownership delivery")
}
core.requireMPVCompatibility(reason: "queue fixture") { completed += 1 }
check(wait(10) { completed == 1 }, "Whole queue installs and exact restore completes")
check(busyChecked, "Busy-list assertion ran against actual MPV restart boundary")
let snapshot = core.mpv.queueSnapshot()
check(snapshot?.entries.map(\.path) == [red.path, blue.path, red.path], "Real MPV readback preserves complete queue")
check(snapshot?.entries.filter(\.current).first?.id == snapshot?.entries.last?.id, "Real MPV selected duplicate is the third unique entry")
check(Set(snapshot?.entries.map(\.id) ?? []).count == 3, "Real duplicate paths have distinct MPV entry IDs")
check(abs(core.mpv.getDouble("time-pos") - 1.2) < 0.05 && core.mpv.getFlag("pause"), "Compatibility resumes same paused position")
check(!core.hasNativePlaybackQueue && !core.isUsingNativePlayback, "Queue owner retires only after real restored transport")
check(core.mpv.getDouble("volume") == 0, "Native and compatibility playback stay silent")
close(core)

let eof = makeCore([red, blue])
eof.playFileInPlaylist(1)
check(wait { eof.info.currentURL == blue && eof.info.state == .paused }, "EOF scenario selects last native item")
eof.seek(absoluteSecond: 4.7); eof.resume()
check(wait { eof.nativeQueue?.phase == .ended }, "Off-mode final item consumes real session EOF once")
let endedToken = eof.nativeQueue?.mediaToken
let invalidSeek = eof.playbackTransport.seek(.init(value: .nan, reference: .absoluteSeconds, exact: true))
if case .invalidInput = invalidSeek { check(eof.playbackAtEOF, "Rejected seek preserves the actual EOF state") }
else { check(false, "Rejected seek preserves the actual EOF state") }
eof.seek(absoluteSecond: 1.1)
check(!eof.playbackAtEOF, "Accepted seek clears cached EOF before worker delivery")
check(wait { eof.info.state == .paused && abs((eof.playbackPosition ?? -1) - 1.1) < 0.05 }, "Seek away from EOF reaches actual paused clock")
eof.resume()
check((eof.playbackPosition ?? -1) >= 1.1, "Resume after accepted EOF seek does not issue a rewind")
check(wait { eof.info.state == .playing && (eof.playbackPosition ?? 0) > 1.15 }, "Resume after accepted EOF seek continues target")
check(eof.nativeQueue?.mediaToken == endedToken, "Accepted EOF seek does not reopen the media generation")
eof.seek(absoluteSecond: 4.7)
check(wait { eof.nativeQueue?.phase == .ended && eof.playbackAtEOF }, "A later actual EOF restores the terminal state after accepted seek")
eof.pause(); close(eof)

let eofLoop = makeCore([red, blue])
eofLoop.playFileInPlaylist(1)
check(wait { eofLoop.info.currentURL == blue && eofLoop.info.state == .paused },
      "EOF marker scenario selects the final native item")
var capturedA = false, capturedB = false
eofLoop.requestNativeLoopAction(.captureA) { if case .applied = $0 { capturedA = true } }
check(wait { capturedA && eofLoop.playbackLoopA == 0 }, "EOF marker scenario captures an exact zero start")
eofLoop.seek(absoluteSecond: 4.7); eofLoop.resume()
check(wait { eofLoop.nativeQueue?.phase == .ended }, "EOF marker scenario reaches the actual terminal sample")
let eofLoopMedia = eofLoop.nativeQueue?.mediaToken
eofLoop.requestNativeLoopAction(.captureB) { if case .applied = $0 { capturedB = true } }
check(wait { capturedB && eofLoop.nativeTransport?.snapshot?.phase == .paused &&
             abs(eofLoop.nativeTransport?.snapshot?.position ?? -1) < 0.05 },
      "Capture B at EOF performs the real paused seek to A")
check(eofLoop.playbackLoopA == 0 && abs((eofLoop.playbackLoopB ?? -1) - 5) < 0.05,
      "Capture B at EOF preserves the requested complete interval")
let markerSeekRevision = eofLoop.nativeTransport?.snapshot?.revision
eofLoop.resume()
check(wait { eofLoop.info.state == .playing && (eofLoop.playbackPosition ?? 0) > 0.05 },
      "Resume after the EOF marker seek advances the real clock")
check(eofLoop.nativeQueue?.mediaToken == eofLoopMedia,
      "Accepted EOF marker seek does not reopen the queue generation")
check(eofLoop.nativeTransport?.snapshot?.revision == markerSeekRevision,
      "Resume after accepted EOF marker seek does not issue another seek")
check(eofLoop.playbackLoopA == 0 && abs((eofLoop.playbackLoopB ?? -1) - 5) < 0.05,
      "Resume after the EOF marker seek retains both A and B")
eofLoop.pause(); close(eofLoop)

let eofPreview = makeCore([red, blue])
eofPreview.playFileInPlaylist(1)
check(wait { eofPreview.info.currentURL == blue && eofPreview.info.state == .paused },
      "EOF preview scenario selects the final native item")
eofPreview.seek(absoluteSecond: 4.7); eofPreview.resume()
check(wait { eofPreview.nativeQueue?.phase == .ended }, "EOF preview scenario consumes actual EOF")
let eofPreviewMedia = eofPreview.nativeQueue?.mediaToken
var eofPreviewStarted = false, eofPreviewFinished = false
eofPreview.requestNativePreview(start: 1, end: 2) { if case .applied = $0 { eofPreviewStarted = true } }
check(wait { eofPreviewStarted && eofPreview.info.state == .playing && (eofPreview.playbackPosition ?? 0) >= 1 },
      "Temporary preview starts from the EOF baseline")
eofPreview.pause()
check(wait { eofPreview.info.state == .paused }, "Temporary EOF preview accepts pause")
eofPreview.resume()
check(wait { eofPreview.info.state == .playing }, "Temporary EOF preview accepts resume")
check(eofPreview.nativeQueue?.mediaToken == eofPreviewMedia && eofPreview.nativePreviewBaseline != nil,
      "Temporary EOF preview resume preserves the queue generation and baseline")
eofPreview.finishNativePreview { if case .applied = $0 { eofPreviewFinished = true } }
check(wait { eofPreviewFinished && eofPreview.playbackAtEOF && eofPreview.playbackIsPaused },
      "Finishing temporary preview restores the paused EOF baseline")
check(eofPreview.nativeQueue?.phase == .ended,
      "Temporary preview does not consume the persistent terminal queue state")
eofPreview.resume()
check(wait { eofPreview.info.state == .playing && eofPreview.nativeQueue?.mediaToken == eofPreviewMedia && (eofPreview.playbackPosition ?? 10) < 1 },
      "Resume after finishing the EOF preview still performs ordinary replay")
eofPreview.pause(); close(eofPreview)

let playingPreview = makeCore([red, blue])
playingPreview.seek(absoluteSecond: 4.4); playingPreview.resume()
check(wait { playingPreview.info.state == .playing && (playingPreview.playbackPosition ?? 0) >= 4.4 },
      "Playing preview scenario captures a nonterminal playing baseline")
var playingPreviewStarted = false, playingPreviewFinished = false
playingPreview.requestNativePreview(start: 1, end: 2) { if case .applied = $0 { playingPreviewStarted = true } }
check(wait { playingPreviewStarted && playingPreview.info.state == .playing && (playingPreview.playbackPosition ?? 0) >= 1 },
      "Temporary preview starts from the playing baseline")
playingPreview.pause()
check(wait { playingPreview.info.state == .paused }, "Temporary playing preview accepts pause")
playingPreview.finishNativePreview { if case .applied = $0 { playingPreviewFinished = true } }
check(wait { playingPreviewFinished && playingPreview.info.state == .playing },
      "Finishing temporary preview restores actual playing transport")
check(playingPreview.nativeQueue?.intent == .playing,
      "Temporary preview pause preserves the persistent playing queue intent")
check(wait { playingPreview.nativeQueue?.selectedIndex == 1 && playingPreview.info.currentURL == blue && playingPreview.info.state == .paused && playingPreview.nativeQueue?.intent == .paused },
      "Restored playing preview advances at EOF and honors pause-on-open")
playingPreview.pause(); close(playingPreview)

let pendingPreview = makeCore([red, blue])
pendingPreview.resume()
check(wait { pendingPreview.info.state == .playing }, "Pending preview scenario starts actual playback")
var pendingPreviewResult: PlayerCore.NativePreviewResult?
pendingPreview.requestNativePreview(start: 1, end: 2) { pendingPreviewResult = $0 }
check(pendingPreview.nativePreviewRequestID != nil && pendingPreview.nativePreviewBaseline == nil,
      "Pending capture has not yet established a temporary preview baseline")
pendingPreview.pause()
check(wait { pendingPreviewResult != nil && pendingPreview.info.state == .paused },
      "Pause cancels the pending preview capture and pauses actual playback")
check(pendingPreview.nativeQueue?.intent == .paused && !pendingPreview.nativePreviewInProgress,
      "Pause during capture still updates the persistent queue intent")
if case .superseded? = pendingPreviewResult {
  check(true, "Cancelled preview capture completes as superseded")
} else {
  check(false, "Cancelled preview capture completes as superseded")
}
close(pendingPreview)

let cancelledPreview = makeCore([red, blue])
var cancelledPreviewStarted = false
cancelledPreview.requestNativePreview(start: 1, end: 2) { if case .applied = $0 { cancelledPreviewStarted = true } }
check(wait { cancelledPreviewStarted && cancelledPreview.info.state == .playing },
      "Preview cancellation case starts from a paused persistent baseline")
cancelledPreview.seek(absoluteSecond: 4.7)
check(wait { !cancelledPreview.nativePreviewInProgress && cancelledPreview.info.state == .playing && (cancelledPreview.playbackPosition ?? 0) >= 4.7 },
      "Explicit seek cancels preview while preserving actual playing transport")
check(cancelledPreview.nativeQueue?.intent == .playing,
      "Accepted preview-cancelling seek adopts the current persistent playback intent")
check(wait { cancelledPreview.nativeQueue?.selectedIndex == 1 && cancelledPreview.info.currentURL == blue && cancelledPreview.info.state == .paused && cancelledPreview.nativeQueue?.intent == .paused },
      "Preview-cancelling seek can advance at EOF with pause-on-open")
close(cancelledPreview)

let fallback = makeCore([red, unsupported, blue, red])
fallback.playFileInPlaylist(1)
check(wait(10) { !fallback.hasNativePlaybackQueue && !fallback.isUsingNativePlayback && fallback.info.state.loaded },
      "Unsupported selected multi-audio item hands whole queue to real MPV")
let fallbackSnapshot = fallback.mpv.queueSnapshot()
check(fallbackSnapshot?.entries.map(\.path) == [red.path, unsupported.path, blue.path, red.path],
      "Unsupported fallback retains both prefix and suffix including repeated path")
check(fallbackSnapshot?.entries.firstIndex(where: \.current) == 1 && fallback.mpv.getFlag("pause"),
      "Unsupported fallback selects correct actual MPV item without autoplay")
check(fallback.mpv.getDouble("volume") == 0, "Capability rejection cannot start audible playback")
close(fallback)

let rapid = makeCore([red, blue, red])
rapid.playFileInPlaylist(1); rapid.playFileInPlaylist(2); rapid.playFileInPlaylist(1)
check(wait { rapid.info.currentURL == blue && rapid.info.state == .paused && rapid.nativeQueue?.selectedIndex == 1 },
      "Latest rapid selection replaces retired and inventory continuations")
check(rapid.mpv.client.appendCalls == 0, "Rapid native selections never append to idle MPV")
close(rapid)

let reentry = makeCore([red, blue, red])
var trackReentered = false, staleCompletion = 0
reentry.notificationHook = { name in
  if name == .iinaTracklistChanged && !trackReentered {
    trackReentered = true
    reentry.stop()
  }
}
reentry.requireMPVCompatibility(reason: "track notification cancellation") { staleCompletion += 1 }
check(wait { trackReentered }, "Real extracted fileLoaded reaches synchronous track notification")
_ = wait(0.15) { false }
check(staleCompletion == 0 && reentry.nativeCompatibilityRestore == nil && reentry.nativeQueue == nil,
      "Track notification stop cannot resurrect old queue restore or completion")
reentry.notificationHook = nil; close(reentry)

let intent = makeCore([red, blue, red])
var installIntentChecked = false, intentCompletion = 0
intent.mpv.client.afterCommand = { args in
  guard args.first == "loadfile", !installIntentChecked else { return }
  installIntentChecked = true
  intent.resume(); intent.pause(); intent.seek(absoluteSecond: 1.7)
  intent.mpv.setFlag("mute", true)
  intent.setVolume(43, unmute: true); intent.setSpeed(1.5)
  check(intent.playbackVolume == 43 && intent.currentPlaybackSpeed == 1.5,
        "Installation exposes latest owned volume and speed intent")
  check(intent.mpv.getDouble("volume") == 0 && intent.mpv.getDouble("speed") == 1 && intent.mpv.getFlag("mute"),
        "Installation volume and speed changes do not write the partial MPV backend")
  check(intent.hasPendingNativeQueueRestore && intent.playbackIsPaused,
        "Installation accepts latest same-media pause and seek intent")
  let commands = intent.mpv.client.commandNames
  intent.clearPlaylist(); intent.playlistRemove(0); intent.appendToPlaylist(blue.path)
  check(intent.mpv.client.commandNames == commands, "Partial real MPV prefix rejects external mutable-list writes")
}
var restoreAudioChecked = false
intent.mpv.beforeRestart = {
  guard intent.hasPendingNativeQueueRestore else { return }
  restoreAudioChecked = true
  check(intent.mpv.getDouble("volume") == 43 && intent.mpv.getDouble("speed") == 1.5,
        "Loaded compatibility uses installation-time audio and speed intent")
  intent.setVolume(57, unmute: true); intent.setSpeed(1.75)
  check(intent.playbackVolume == 57 && intent.currentPlaybackSpeed == 1.75,
        "Pending exact restore exposes the newest volume and speed")
  intent.setVolume(.nan); intent.setSpeed(.infinity)
  check(intent.playbackVolume == 57 && intent.currentPlaybackSpeed == 1.75,
        "Pending restore rejects nonfinite volume and speed without changing intent")
  intent.setSpeed(0)
  check(intent.currentPlaybackSpeed == AppData.mpvMinPlaybackSpeed,
        "Pending restore preserves the existing minimum speed policy")
  intent.setVolume(137, constrain: false, unmute: true); intent.setSpeed(2.25)
  check(intent.playbackVolume == 137 && intent.currentPlaybackSpeed == 2.25 && intent.hasPendingNativeQueueRestore,
        "Owned compatibility accepts amplified volume and rates outside native limits")
  intent.info.volume = 43
  check(intent.syncVolumeFromMPV() == 137 && intent.info.volume == 137,
        "Volume UI synchronization preserves latest owned intent before restart")
  intent.speedChanged(1.5)
  check(intent.info.playSpeed == 2.25 && intent.currentPlaybackSpeed == 2.25,
        "Delayed speed property cannot roll back owned presentation intent")
}
intent.requireMPVCompatibility(reason: "installation intent") { intentCompletion += 1 }
check(wait(10) { intentCompletion == 1 }, "Installation with changed intent completes exactly once")
check(installIntentChecked && intent.mpv.getFlag("pause") && abs(intent.mpv.getDouble("time-pos") - 1.7) < 0.05,
      "Final real MPV transport uses latest installation-time position and pause")
check(restoreAudioChecked && intent.mpv.getDouble("volume") == 137 && intent.mpv.getDouble("speed") == 2.25 && !intent.mpv.getFlag("mute") &&
      intent.info.volume == 137 && intent.info.playSpeed == 2.25,
      "Verified restore commits the latest volume speed unmute and UI values")
close(intent)

let cancel = makeCore([red, blue, red])
var cancelledInAppend = false, cancelledCompletion = 0
cancel.mpv.client.afterCommand = { args in
  guard args.first == "loadfile", !cancelledInAppend else { return }
  cancelledInAppend = true; cancel.stop()
}
cancel.requireMPVCompatibility(reason: "stop partial queue") { cancelledCompletion += 1 }
check(wait { cancelledInAppend }, "Cancellation reaches actual first append boundary")
_ = wait(0.2) { false }
check(cancel.nativeQueue == nil && cancel.nativeQueueInstallation == nil && cancel.mpv.owner == nil && cancelledCompletion == 0,
      "Stop invalidates partial installation, event owner and pending action")
check(cancel.mpv.client.appendCalls == 1, "Cancelled installer cannot append old queue suffix")
let cancelledOwner = cancel.mpv.cancelledStopRequests.first ?? UUID()
check(cancel.mpv.preparedStopRequests.first?.owner == cancelledOwner &&
      cancel.mpv.preparedStopRequests.first?.mpvRouteEnabled == false,
      "Cancelled installation prepares event isolation before enabling MPV presentation")
check(cancel.pendingNativeQueueStopOwner == cancelledOwner && cancel.mpv.cancelledStopRequests == [cancelledOwner],
      "Cancelled installation delegates stop with the exact retained owner")
cancel.stop()
check(cancel.pendingNativeQueueStopOwner == cancelledOwner &&
      cancel.mpv.cancelledStopRequests == [cancelledOwner, cancelledOwner],
      "Repeated stop preserves the owned keep-playlist stop protocol")
check(cancel.mpv.acknowledgeCancelledStopForCoreTest() && cancel.info.state == .idle &&
      cancel.pendingNativeQueueStopOwner == nil,
      "Controlled stop acknowledgment clears Core owner at the idle transition")
cancel.mpv.client.afterCommand = nil; close(cancel)

let stoppedPendingOpen = makeCore([red, blue, red])
var heldStop = false
stoppedPendingOpen.mpv.client.afterCommand = { args in
  guard args.first == "loadfile", !heldStop else { return }
  heldStop = true
  stoppedPendingOpen.setVolume(63, unmute: true); stoppedPendingOpen.setSpeed(1.75)
  check(stoppedPendingOpen.playbackVolume == 63 && stoppedPendingOpen.currentPlaybackSpeed == 1.75,
        "Cancelled installation first captures distinct audio and rate intent")
  stoppedPendingOpen.backgroundTaskTickets.insert(1)
  stoppedPendingOpen.stop()
}
stoppedPendingOpen.requireMPVCompatibility(reason: "background stop owner") {
  check(false, "Cancelled background installation must not complete")
}
check(wait { heldStop && stoppedPendingOpen.info.state == .stopping },
      "Background work delays the actual installation stop command")
let heldOwner = stoppedPendingOpen.pendingNativeQueueStopOwner
check(heldOwner != nil && stoppedPendingOpen.mpv.cancelledStopRequests.isEmpty,
      "Installation owner survives the background-task wait without an early command")
check(stoppedPendingOpen.mpv.preparedStopRequests.first?.owner == heldOwner &&
      stoppedPendingOpen.mpv.preparedStopRequests.first?.mpvRouteEnabled == false,
      "Background-delayed stop prepares the event barrier before exposing the new route")
stoppedPendingOpen.open(blue, shouldAutoLoad: false)
check(stoppedPendingOpen.pendingUrl == blue && stoppedPendingOpen.pendingNativeQueueStopOwner == heldOwner,
      "Queued open does not invalidate an unsubmitted owned stop")
stoppedPendingOpen.backgroundTaskTickets.removeAll()
stoppedPendingOpen.stop(); stoppedPendingOpen.stop()
check(stoppedPendingOpen.mpv.cancelledStopRequests == [heldOwner ?? UUID(), heldOwner ?? UUID()],
      "Background completion and repeated stop reuse one installation owner")
stoppedPendingOpen.mpv.client.afterCommand = nil
check(stoppedPendingOpen.mpv.acknowledgeCancelledStopForCoreTest(),
      "Controlled installation-stop service delivers its terminal acknowledgment")
check(wait { stoppedPendingOpen.info.currentURL == blue && stoppedPendingOpen.info.state == .paused &&
             stoppedPendingOpen.pendingUrl == nil && stoppedPendingOpen.pendingNativeQueueStopOwner == nil },
      "Actual Core idle acknowledgment opens and loads the queued replacement")
check(stoppedPendingOpen.nativeCompatibilityRestore == nil && stoppedPendingOpen.mpv.getDouble("volume") == 0 &&
      stoppedPendingOpen.mpv.getDouble("speed") == 1,
      "Replacement does not inherit cancelled handoff volume or speed")
close(stoppedPendingOpen)

let loop = makeCore([red, blue])
loop.applyLoopMode(.file)
loop.seek(absoluteSecond: 4.7); loop.resume()
let loopMedia = loop.nativeQueue?.mediaToken
check(wait { loop.info.state == .playing && (loop.playbackPosition ?? 10) < 0.5 }, "File repeat wraps the real session clock")
check(loop.nativeQueue?.selectedIndex == 0 && loop.nativeQueue?.mediaToken == loopMedia,
      "File repeat keeps a single Session owner and does not double-advance queue")
loop.pause(); loop.applyLoopMode(.playlist); loop.playFileInPlaylist(1)
check(wait { loop.info.currentURL == blue && loop.info.state == .paused }, "Playlist-repeat case selects last native item")
loop.seek(absoluteSecond: 4.7); loop.resume()
check(wait { loop.nativeQueue?.selectedIndex == 0 && loop.info.currentURL == red && loop.info.state == .paused && loop.nativeQueue?.intent == .paused },
      "Playlist repeat advances last real EOF and honors pause-on-open")
check(loop.mpv.client.appendCalls == 0 && loop.playbackVolume == 0,
      "Native playlist EOF does not touch idle MPV or restore prior volume")
loop.pause(); close(loop)

let noSeek = makeCore([red, blue])
noSeek.playFileInPlaylist(1)
check(wait { noSeek.info.currentURL == blue && noSeek.info.state == .paused }, "Unmodified EOF replay case reaches last file")
noSeek.seek(absoluteSecond: 0.4)
check(wait { noSeek.info.state == .paused && abs((noSeek.playbackPosition ?? -1) - 0.4) < 0.05 },
      "EOF replay setup reaches its persistent A marker")
var replayA = false
noSeek.requestNativeLoopAction(.captureA) { if case .applied = $0 { replayA = true } }
check(wait { replayA }, "EOF replay setup retains an A-only marker")
noSeek.seek(absoluteSecond: 4.7); noSeek.resume()
check(wait { noSeek.nativeQueue?.phase == .ended }, "Unmodified EOF replay consumes the terminal sample")
let oldMedia = noSeek.nativeQueue?.mediaToken
let oldSession = noSeek.nativePlaybackSession
let replayViewport = VideoToolsViewport(zoom: 0.5, panX: 0.1, panY: -0.1)
check(noSeek.applyNativeViewport(replayViewport), "EOF replay setup accepts a nondefault viewport")
noSeek.playbackTransport.setVolumePercent(37)
noSeek.resume()
check(wait { noSeek.info.state == .playing && (noSeek.playbackPosition ?? 10) < 1 },
      "EOF resume without an earlier seek rewinds the same queue item")
check(noSeek.nativeQueue?.mediaToken == oldMedia && noSeek.nativePlaybackSession === oldSession,
      "EOF replay seeks within the same media and Session identity")
check(abs(noSeek.playbackVolume - 37) < 0.001 && noSeek.nativeViewport == replayViewport,
      "EOF replay preserves volume and viewport")
check(abs((noSeek.playbackLoopA ?? -1) - 0.4) < 0.05 && noSeek.playbackLoopB == nil,
      "EOF replay preserves the persistent A marker")
noSeek.pause(); close(noSeek)

let firstPrevious = makeCore([red, blue])
firstPrevious.seek(absoluteSecond: 1)
check(wait { firstPrevious.info.state == .paused && abs((firstPrevious.playbackPosition ?? -1) - 1) < 0.05 },
      "First previous setup reaches A")
var previousA = false, previousB = false
firstPrevious.requestNativeLoopAction(.captureA) { if case .applied = $0 { previousA = true } }
check(wait { previousA }, "First previous setup captures A")
firstPrevious.seek(absoluteSecond: 2)
check(wait { firstPrevious.info.state == .paused && abs((firstPrevious.playbackPosition ?? -1) - 2) < 0.05 },
      "First previous setup reaches B")
firstPrevious.requestNativeLoopAction(.captureB) { if case .applied = $0 { previousB = true } }
check(wait { previousB && firstPrevious.info.state == .paused && abs((firstPrevious.playbackPosition ?? -1) - 1) < 0.05 },
      "First previous setup has a paused nonzero A-B interval")
let previousMedia = firstPrevious.nativeQueue?.mediaToken
let previousSession = firstPrevious.nativePlaybackSession
Preference.pauseWhenOpen = false
firstPrevious.navigateInPlaylist(nextMedia: false)
check(wait { firstPrevious.info.state == .paused && abs((firstPrevious.playbackPosition ?? -1) - 1) < 0.05 },
      "First previous preserves pause and clamps rewind to the existing A-B range")
check(firstPrevious.nativeQueue?.mediaToken == previousMedia && firstPrevious.nativePlaybackSession === previousSession,
      "First previous does not reload the current Session")
check(firstPrevious.playbackLoopA == 1 && firstPrevious.playbackLoopB == 2,
      "First previous retains both loop markers")
Preference.pauseWhenOpen = true
close(firstPrevious)

let autoPlaying = makeCore([red, blue])
Preference.pauseWhenOpen = false
autoPlaying.seek(absoluteSecond: 4.7); autoPlaying.resume()
check(wait { autoPlaying.nativeQueue?.selectedIndex == 1 && autoPlaying.info.currentURL == blue && autoPlaying.info.state == .playing },
      "Automatic next plays when pause-on-open is disabled")
Preference.pauseWhenOpen = true
autoPlaying.pause(); close(autoPlaying)

let disableAdvance = makeCore([red, blue])
Preference.playlistAutoPlayNext = false
disableAdvance.seek(absoluteSecond: 4.7); disableAdvance.resume()
check(wait { disableAdvance.nativeQueue?.phase == .ended && disableAdvance.nativeQueue?.selectedIndex == 0 && disableAdvance.info.currentURL == red },
      "Disabling automatic next during native playback is honored at actual EOF")
close(disableAdvance)
let enableAdvance = makeCore([red, blue])
Preference.playlistAutoPlayNext = true
enableAdvance.seek(absoluteSecond: 4.7); enableAdvance.resume()
check(wait { enableAdvance.nativeQueue?.selectedIndex == 1 && enableAdvance.info.currentURL == blue && enableAdvance.info.state == .paused },
      "Enabling automatic next during native playback is honored at actual EOF")
close(enableAdvance)

let delayedEOF = makeCore([red, blue])
delayedEOF.seek(absoluteSecond: 4.7); delayedEOF.resume()
check(wait { delayedEOF.info.state == .playing && (delayedEOF.playbackPosition ?? 0) >= 4.7 },
      "Delayed EOF scenario reaches actual near-end playback")
if let session = delayedEOF.nativePlaybackSession,
   let worker = Mirror(reflecting: session).children.first(where: { $0.label == "worker" })?.value as? DispatchQueue {
  let oldRevision = delayedEOF.nativeTransport?.snapshot?.revision
  let observer = session.onSnapshot
  var staleEOFDelivered = false
  session.onSnapshot = { value in
    if value.phase == .ended && value.revision == oldRevision { staleEOFDelivered = true }
    observer?(value)
  }
  // Deliberately hold this test's main run loop, not the worker. The worker can
  // end and queue its original callback before the user accepts a new seek.
  let probe = DelayedEOFProbe(session: session, worker: worker)
  worker.async { probe.sample() }
  let observed = probe.completed.wait(timeout: probe.deadline) == .success
  let observation = probe.read()
  check(observed && observation.ended, "Delayed EOF exists on the real worker before accepted seek")
  if !observed || !observation.ended {
    print("EOF_DIAGNOSTIC: time=\(observation.time) rate=\(observation.rate)")
  }
  delayedEOF.seek(absoluteSecond: 1); delayedEOF.pause()
  check(wait { delayedEOF.info.state == .paused && abs((delayedEOF.playbackPosition ?? -1) - 1) < 0.05 },
        "Accepted seek settles after an already queued EOF callback")
  check(!staleEOFDelivered && delayedEOF.nativeQueue?.selectedIndex == 0 && delayedEOF.nativeQueue?.phase == .ready,
        "Production Session revision gate rejects queued EOF after accepted seek")
} else { check(false, "Delayed EOF fixture locates only the immutable worker queue") }
close(delayedEOF)

let sourceReentry = makeCore([red, blue])
var stoppedOnSource = false
sourceReentry.notificationHook = { name in
  if name == .chengyingMediaSourceChanged && !stoppedOnSource {
    stoppedOnSource = true; sourceReentry.stop()
  }
}
sourceReentry.playFileInPlaylist(1)
check(wait { stoppedOnSource && !sourceReentry.isUsingNativePlayback }, "New native source notification permits stop to take priority")
check(sourceReentry.nativeQueue == nil && sourceReentry.mpv.client.appendCalls == 0,
      "Stopped source notification cannot start a stale Session or compatibility load")
sourceReentry.notificationHook = nil; close(sourceReentry)

let rotation = makeCore([red, blue, red])
var accumulatedDuringInstall = false
let rotationCount = deliveredRotations.count
rotation.mpv.client.afterCommand = { args in
  guard args.first == "loadfile", !accumulatedDuringInstall else { return }
  accumulatedDuringInstall = true
  check(rotation.requestPermanentRotation(clockwiseQuarterTurns: 1),
        "Owned permanent rotation accumulates during whole-queue installation")
}
check(rotation.requestPermanentRotation(clockwiseQuarterTurns: 1), "First rotation requests an owned whole-queue handoff")
check(wait(10) { deliveredRotations.count == rotationCount + 1 }, "Rotation action delivers after real queue and transport verification")
check(accumulatedDuringInstall && deliveredRotations.last?.1 == 2 && deliveredRotations.last?.0 == red,
      "Rapid rotation retains exact accumulated quarters and source identity")
check(rotation.mpv.queueSnapshot()?.entries.map(\.path) == [red.path, blue.path, red.path],
      "Rotation compatibility action retains the complete real MPV queue")
close(rotation)

let reopen = makeCore([red, blue])
reopen.playFileInPlaylist(1)
check(reopen.openMediaURLs([red, blue, red], shouldAutoLoad: false) == 3,
      "Explicit duplicate open reports full count while retiring the prior native selection")
check(wait { reopen.isUsingNativePlayback && reopen.info.state == .paused && reopen.info.playlist.count == 3 },
      "New explicit queue cancels prior pending selection and keeps all duplicate items")
check(reopen.info.currentURL == red && reopen.info.playlist.map(\.filename) == [red.path, blue.path, red.path],
      "Reopened explicit queue installs its own complete native projection")
close(reopen)
print("RESULT: \(passes) checks passed, \(failures) failures")
exit(failures == 0 ? 0 : 1)
