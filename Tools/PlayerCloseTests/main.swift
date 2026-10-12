import Cocoa

let hardwareRequested = (ProcessInfo.processInfo.environment["CLOSE_TEST_HWDEC"] ?? "no") != "no"
let forceSoftwareGL = ProcessInfo.processInfo.environment["CHENGYING_TEST_SOFTWARE_GL"] == "1"
if hardwareRequested && forceSoftwareGL {
  fputs("FAIL: Hardware decoding cannot be verified with forced software OpenGL\n", stderr)
  exit(1)
}

NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.finishLaunching()
let player = PlayerCore()
let video = VideoView(player: player)
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 360),
                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.title = "Player Close Regression"
window.contentView = video
player.mpv.startRendering(layer: video.videoLayer)

var loadedFiles = 0
var playbackRestarts = 0
var position: Double?
var diagnosticLog = Data()
var diagnosticLogTruncated = false
var diagnosticReplies: [UInt64: Int32] = [:]
var loadRound = -1
var expectedLoadedFiles = 0
var loadStartedAt = ProcessInfo.processInfo.systemUptime
var lifecycleEvents: [[String: Any]] = []
var discardedLifecycleEvents = 0
var startedFiles = 0
var endedFiles = 0
var lastEndReason: Int32?
var lastEndError: Int32?
var renderStateSamples: [[String: Any]] = []

func renderStateSnapshot(_ phase: String) -> [String: Any] {
  let layer = video.videoLayer
  return ["phase": phase, "round": loadRound,
          "elapsed": ProcessInfo.processInfo.systemUptime - loadStartedAt,
          "position": position ?? -1, "updates": ObservedLayer.updateRequests,
          "forced_updates": ObservedLayer.forcedUpdateRequests,
          "display_calls": ObservedLayer.displayCalls, "completed_display_calls": ObservedLayer.completedDisplayCalls,
          "can_draw": ObservedLayer.readinessChecks, "accepted_can_draw": ObservedLayer.acceptedReadinessChecks,
          "frames": ObservedLayer.frames, "pictures": ObservedLayer.pictureFrames,
          "window_visible": window.isVisible, "window_occlusion_visible": window.occlusionState.contains(.visible),
          "window_occlusion_raw": window.occlusionState.rawValue, "window_on_active_space": window.isOnActiveSpace,
          "window_number": window.windowNumber, "window_alpha": window.alphaValue,
          "window_miniaturized": window.isMiniaturized, "window_animation_behavior": window.animationBehavior.rawValue,
          "application_active": NSApp.isActive, "application_hidden": NSApp.isHidden,
          "view_has_window": video.window === window, "view_hidden": video.isHiddenOrHasHiddenAncestor,
          "view_visible_rect": NSStringFromRect(video.visibleRect), "layer_hidden": layer.isHidden,
          "layer_opacity": layer.opacity, "layer_bounds": NSStringFromRect(layer.bounds),
          "layer_needs_display": layer.needsDisplay(), "layer_asynchronous": layer.isAsynchronous,
          "layer_animation_keys": layer.animationKeys() ?? []]
}

func recordLifecycleEvent(_ event: mpv_event) {
  let relevant = [MPV_EVENT_START_FILE, MPV_EVENT_FILE_LOADED, MPV_EVENT_PLAYBACK_RESTART,
                  MPV_EVENT_END_FILE, MPV_EVENT_COMMAND_REPLY, MPV_EVENT_QUEUE_OVERFLOW]
  guard relevant.contains(event.event_id) else { return }
  var entry: [String: Any] = ["event": String(cString: mpv_event_name(event.event_id)),
                            "round": loadRound, "elapsed": ProcessInfo.processInfo.systemUptime - loadStartedAt,
                            "error": event.error, "reply_userdata": event.reply_userdata]
  if event.event_id == MPV_EVENT_START_FILE { startedFiles += 1 }
  if event.event_id == MPV_EVENT_END_FILE,
     let result = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
    endedFiles += 1
    lastEndReason = Int32(result.reason.rawValue)
    lastEndError = result.error
    entry["end_reason"] = lastEndReason
    entry["end_error"] = result.error
  }
  if lifecycleEvents.count == 128 {
    lifecycleEvents.removeFirst()
    discardedLifecycleEvents += 1
  }
  lifecycleEvents.append(entry)
}

func captureLoadFailureDiagnostics(_ reason: String) {
  let summary: [String: Any] = ["diagnostic_only": true, "reason": reason, "round": loadRound,
    "elapsed": ProcessInfo.processInfo.systemUptime - loadStartedAt,
    "expected_loaded": expectedLoadedFiles, "loaded": loadedFiles,
    "started": startedFiles, "ended": endedFiles, "restarts": playbackRestarts,
    "last_end_reason": lastEndReason.map { $0 as Any } ?? NSNull(),
    "last_end_error": lastEndError.map { $0 as Any } ?? NSNull(),
    "discarded_lifecycle_events": discardedLifecycleEvents, "events": lifecycleEvents,
    "log_truncated": diagnosticLogTruncated]
  if let compact = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]) {
    print("LOAD_FAILURE: \(String(decoding: compact, as: UTF8.self))")
  } else {
    print("LOAD_FAILURE: round=\(loadRound), expected=\(expectedLoadedFiles), loaded=\(loadedFiles)")
  }
  if let directory = failureDiagnosticDirectory {
    do {
      try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("load-failure.json"), options: .atomic)
      try diagnosticLog.write(to: directory.appendingPathComponent("load-failure.log"), options: .atomic)
    } catch {
      print("LOAD_FAILURE: unable to persist load failure diagnostics")
    }
  }
  fflush(stdout)
}

func drainMPVEvents() {
    while let event = mpv_wait_event(player.mpv.mpv, 0), event.pointee.event_id != MPV_EVENT_NONE {
      recordLifecycleEvent(event.pointee)
      if event.pointee.event_id == MPV_EVENT_LOG_MESSAGE,
         let message = event.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee {
        let text = "[\(String(cString: message.prefix))] \(String(cString: message.level)): \(String(cString: message.text))"
        if let bytes = text.data(using: .utf8), diagnosticLog.count + bytes.count <= 2_097_152 {
          diagnosticLog.append(bytes)
        } else {
          diagnosticLogTruncated = true
          _ = mpv_request_log_messages(player.mpv.mpv, "no")
        }
      }
      if event.pointee.event_id == MPV_EVENT_COMMAND_REPLY {
        diagnosticReplies[event.pointee.reply_userdata] = event.pointee.error
      }
      if event.pointee.event_id == MPV_EVENT_FILE_LOADED { loadedFiles += 1 }
      if event.pointee.event_id == MPV_EVENT_PLAYBACK_RESTART { playbackRestarts += 1 }
      if event.pointee.event_id == MPV_EVENT_PROPERTY_CHANGE,
         let property = event.pointee.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
         String(cString: property.name) == "time-pos", property.format == MPV_FORMAT_DOUBLE,
         let value = property.data?.assumingMemoryBound(to: Double.self).pointee {
        position = value
      }
      if event.pointee.event_id == MPV_EVENT_END_FILE,
         let result = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
        if result.reason == MPV_END_FILE_REASON_ERROR { captureLoadFailureDiagnostics("decode-error") }
        precondition(result.reason != MPV_END_FILE_REASON_ERROR, "The generated media must decode successfully")
      }
    }
}

func pump(_ seconds: Double) {
  let end = ProcessInfo.processInfo.systemUptime + seconds
  while ProcessInfo.processInfo.systemUptime < end {
    drainMPVEvents()
    PlayerCloseWindowLifecycle.dispatchEvents(until: end)
    let remaining = end - ProcessInfo.processInfo.systemUptime
    if remaining > 0 { RunLoop.main.run(until: Date().addingTimeInterval(min(remaining, 0.005))) }
  }
}

func savePassDiagnostics(_ name: String, directory: URL) throws {
  guard playerCloseGLPassDiagnosticsEnabled else { return }
  try Data(playerCloseGLPassDiagnosticsJSON().utf8)
    .write(to: directory.appendingPathComponent("\(name)-passes.json"), options: .atomic)
  try JSONSerialization.data(withJSONObject: playerCloseGLInitUnpackSnapshots, options: [.prettyPrinted, .sortedKeys])
    .write(to: directory.appendingPathComponent("init-unpack.json"), options: .atomic)
}

func captureFailureDiagnostics(index: Int, frameDelta: Int, pictureDelta: Int) {
  guard let directory = failureDiagnosticDirectory else { return }
  do {
    renderStateSamples.append(renderStateSnapshot("failure-before-screenshots"))
    try JSONSerialization.data(withJSONObject: renderStateSamples, options: [.prettyPrinted, .sortedKeys])
      .write(to: directory.appendingPathComponent("render-state.json"), options: .atomic)
    try diagnosticLog.write(to: directory.appendingPathComponent("before-screenshots.log"), options: .atomic)
    try savePassDiagnostics("before-screenshots", directory: directory)
    if ProcessInfo.processInfo.environment["CLOSE_TEST_RENDER_STATE_ONLY"] == "1" {
      print("FAILURE_DIAGNOSTICS: round=\(index), render_state_only=true, screenshots=0")
      fflush(stdout)
      return
    }
    var screenshots: [[String: Any]] = []
    for (offset, mode) in ["video", "window"].enumerated() {
      let identifier = UInt64(1001 + offset)
      let output = directory.appendingPathComponent("\(mode).png")
      let submitted = player.mpv.diagnosticCommand(["screenshot-to-file", output.path, mode], identifier: identifier)
      let deadline = Date().addingTimeInterval(20)
      while submitted >= 0 && diagnosticReplies[identifier] == nil && Date() < deadline { pump(0.01) }
      screenshots.append(["mode": mode, "submitted": submitted,
                          "reply": diagnosticReplies[identifier].map { $0 as Any } ?? NSNull(),
                          "file_exists": FileManager.default.fileExists(atPath: output.path)])
    }
    // The software control bypasses the GPU screenshot render path. Run it
    // only after both GPU requests completed, so their settings stay unchanged.
    if diagnosticReplies[1001] != nil && diagnosticReplies[1002] != nil {
      let configured = mpv_set_property_string(player.mpv.mpv, "screenshot-sw", "yes")
      let output = directory.appendingPathComponent("source-software.png")
      let submitted = configured >= 0
        ? player.mpv.diagnosticCommand(["screenshot-to-file", output.path, "video"], identifier: 1003) : configured
      let deadline = Date().addingTimeInterval(20)
      while submitted >= 0 && diagnosticReplies[1003] == nil && Date() < deadline { pump(0.01) }
      screenshots.append(["mode": "source-software", "configured": configured, "submitted": submitted,
                          "reply": diagnosticReplies[1003].map { $0 as Any } ?? NSNull(),
                          "file_exists": FileManager.default.fileExists(atPath: output.path)])
    }
    try diagnosticLog.write(to: directory.appendingPathComponent("after-screenshots.log"), options: .atomic)
    try savePassDiagnostics("after-screenshots", directory: directory)
    let summary: [String: Any] = ["diagnostic_only": true, "original_failed_round": index,
                                 "original_frames": frameDelta, "original_pictures": pictureDelta,
                                 "pictures_after_screenshots": ObservedLayer.pictureFrames,
                                 "position_after_screenshots": position ?? -1,
                                 "log_truncated": diagnosticLogTruncated,
                                 "screenshots": screenshots]
    try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
      .write(to: directory.appendingPathComponent("failure.json"), options: .atomic)
    print("FAILURE_DIAGNOSTICS: round=\(index), screenshots=\(screenshots.count), log_truncated=\(diagnosticLogTruncated)")
  } catch {
    print("FAILURE_DIAGNOSTICS: unable to persist diagnostic output")
  }
  fflush(stdout)
}

final class CloseDelegate: NSObject, NSWindowDelegate {
  let player: PlayerCore
  var preview = false
  init(player: PlayerCore) { self.player = player }
  func windowWillClose(_ notification: Notification) {
    if preview {
      player.mpv.setString("ab-loop-count", "0")
      player.mpv.setString("ab-loop-a", "no")
      player.mpv.setString("ab-loop-b", "no")
      player.mpv.setString("video-rotate", "0")
      player.mpv.command(["seek", "0.5", "absolute+exact"])
      player.mpv.setString("pause", "no")
    }
    player.mpv.setString("pause", "yes")
    player.mpv.command(["stop"])
  }
}
let delegate = CloseDelegate(player: player)
window.delegate = delegate
let media = CommandLine.arguments[1]
var decoders = Set<String>()
for index in 0..<30 {
  NSApp.activate(ignoringOtherApps: true)
  window.makeKeyAndOrderFront(nil)
  delegate.preview = index % 2 == 0
  let initialRestarts = playbackRestarts
  position = nil
  loadRound = index
  expectedLoadedFiles = index + 1
  loadStartedAt = ProcessInfo.processInfo.systemUptime
  player.mpv.command(["loadfile", media])
  player.mpv.setString("pause", "no")
  let loadPassed = PlayerCloseLoadWaiter.wait(expected: expectedLoadedFiles, timeout: 3,
    loaded: { loadedFiles }, clock: { ProcessInfo.processInfo.systemUptime }, pump: pump, drain: drainMPVEvents)
  let loadElapsed = ProcessInfo.processInfo.systemUptime - loadStartedAt
  if !loadPassed { captureLoadFailureDiagnostics("file-loaded-not-observed") }
  precondition(loadPassed, "Every reopened file must complete loading before its close probe")
  let initialFrames = ObservedLayer.frames
  let initialPictures = ObservedLayer.pictureFrames
  let initialPosition = position ?? 0
  if failureDiagnosticDirectory != nil {
    renderStateSamples = [renderStateSnapshot("readiness-start")]
  }
  var nextRenderStateSample = ProcessInfo.processInfo.systemUptime + 0.25
  let readinessStarted = Date()
  let frameDeadline = Date().addingTimeInterval(8)
  while (!PlayerCloseWindowLifecycle.isVisible(window) ||
         ObservedLayer.pictureFrames < initialPictures + 2 || playbackRestarts <= initialRestarts ||
         (position ?? 0) <= initialPosition + 0.01),
        Date() < frameDeadline {
    pump(0.01)
    if failureDiagnosticDirectory != nil, ProcessInfo.processInfo.systemUptime >= nextRenderStateSample {
      renderStateSamples.append(renderStateSnapshot("readiness-wait"))
      nextRenderStateSample = ProcessInfo.processInfo.systemUptime + 0.25
    }
  }
  let frameDelta = ObservedLayer.frames - initialFrames
  let pictureDelta = ObservedLayer.pictureFrames - initialPictures
  let readyAfter = Date().timeIntervalSince(readinessStarted)
  print("READY: \(index), loaded=\(loadedFiles), frames=\(frameDelta), pictures=\(pictureDelta), restarts=\(playbackRestarts - initialRestarts), position=\(position ?? -1), loadWait=\(String(format: "%.3f", loadElapsed))s, wait=\(String(format: "%.3f", readyAfter))s, canDraw=\(ObservedLayer.acceptedReadinessChecks)/\(ObservedLayer.readinessChecks), visible=\(window.isVisible), activeSpace=\(window.isOnActiveSpace), unoccluded=\(window.occlusionState.contains(.visible)), bounds=\(video.videoLayer.bounds)")
  fflush(stdout)
  let readinessPassed = PlayerCloseWindowLifecycle.isVisible(window) &&
    frameDelta >= 2 && pictureDelta >= 2 && playbackRestarts > initialRestarts &&
    (position ?? 0) > initialPosition + 0.01
  if index == 0, let directory = failureDiagnosticDirectory {
    do {
      try diagnosticLog.write(to: directory.appendingPathComponent("first-ready.log"), options: .atomic)
      try savePassDiagnostics("first-ready", directory: directory)
    } catch {
      print("FAILURE_DIAGNOSTICS: unable to persist first-ready log")
    }
  }
  if !readinessPassed { captureFailureDiagnostics(index: index, frameDelta: frameDelta, pictureDelta: pictureDelta) }
  precondition(readinessPassed,
               "Each reopened media must display two decoded pictures and advance playback")
  if let decoder = player.mpv.getString("hwdec-current") { decoders.insert(decoder) }
  if delegate.preview {
    player.mpv.setString("video-rotate", "90")
    player.mpv.setString("ab-loop-a", "0.25")
    player.mpv.setString("ab-loop-b", "1.25")
    player.mpv.setString("ab-loop-count", "inf")
  }
  print("CLOSE: \(index), preview=\(delegate.preview)")
  fflush(stdout)
  window.close()
  pump(0.03)
}
player.mpv.finish(view: video)
if let directory = failureDiagnosticDirectory {
  do {
    try savePassDiagnostics("final", directory: directory)
  } catch {
    print("FAILURE_DIAGNOSTICS: unable to persist final pass log")
  }
}
precondition(ObservedLayer.frames > 30, "The real OpenGL layer must render frames")
precondition(ObservedLayer.pictureFrames >= 60, "Every close must follow two verified video pictures")
if let requested = ProcessInfo.processInfo.environment["CLOSE_TEST_HWDEC"], requested != "no" {
  precondition(decoders.contains(requested), "The requested hardware decoder must actually be observed")
}
print("PASS: Close and reopen stress completed, loaded=\(loadedFiles), rendered=\(ObservedLayer.frames), pictures=\(ObservedLayer.pictureFrames), decoders=\(decoders.sorted())")
