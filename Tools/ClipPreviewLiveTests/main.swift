import Cocoa

setbuf(stdout, nil)
struct TestFailure: Error { let message: String }
var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw TestFailure(message: message) }
  assertions += 1
  print("PASS: \(message)")
}
func argument(_ name: String) -> String? {
  guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
  return CommandLine.arguments[index + 1]
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.finishLaunching()
var failures = 0

func run() throws {
  guard let path = argument("--media") else { throw TestFailure(message: "A local test media argument is required") }
  guard let runLoopStall = Double(ProcessInfo.processInfo.environment["CHENGYING_PREVIEW_RUN_LOOP_STALL"] ?? "0"),
        runLoopStall.isFinite, (0...1).contains(runLoopStall) else {
    throw TestFailure(message: "CHENGYING_PREVIEW_RUN_LOOP_STALL must be between 0 and 1 second")
  }
  let player = PlayerCore()
  let mpv = player.mpv
  let media = URL(fileURLWithPath: path)
  player.info.currentURL = media
  mpv.rawCommand(["loadfile", media.path, "replace"])

  func pump(_ seconds: Double) {
    let deadline = LiveClock.now + seconds
    repeat {
      player.processEvents()
      while let event = application.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
        application.sendEvent(event)
      }
      application.updateWindows()
      RunLoop.main.run(until: Date().addingTimeInterval(0.003))
    } while LiveClock.now < deadline && mpv.error == nil
  }
  func until(_ message: String, timeout: Double = 3, _ condition: () -> Bool) throws {
    let deadline = LiveClock.now + timeout
    while !condition(), LiveClock.now < deadline, mpv.error == nil { pump(0.015) }
    try check(mpv.error == nil, mpv.error ?? "The real playback boundary remains healthy")
    try check(condition(), message)
  }
  try until("Generated or explicitly supplied local video loads and renders", timeout: 15) {
    player.info.state.loaded && clip_renderer_frames() > 0
  }
  let duration = player.info.videoDuration?.second ?? 0
  try check(duration > 6, "The real video duration supports independent preview intervals")
  print(String(format: "PLAYER: libmpv software decode/render; duration=%.9f; source=%@", duration,
               CommandLine.arguments.contains("--synthetic") ? "synthetic" : "external-read-only"))

  let controller = VideoToolsViewController(player: player, mainWindow: player.mainWindow)
  _ = controller.view
  pump(0.5)
  try check(player.videoToolsLoopRange == nil && mpv.getFlag(MPVOption.PlaybackControl.pause),
            "Preloading the hidden production tools tab does not start playback")
  let parent = QuickSettingViewController(tools: controller, mainWindow: player.mainWindow)
  let panel = NSWindow(contentRect: NSRect(x: 750, y: 120, width: 380, height: 850),
                       styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
  panel.isReleasedWhenClosed = false
  panel.title = "Clip Preview Live Test - Production Controls"
  panel.contentViewController = parent
  panel.makeKeyAndOrderFront(nil)
  application.activate(ignoringOtherApps: true)
  controller.view.layoutSubtreeIfNeeded()
  defer {
    controller.stopPreview()
    controller.setPlaybackControlsVisible(false)
    panel.makeFirstResponder(nil)
    panel.close()
  }

  func property<T>(_ name: String, _: T.Type) -> T {
    guard let value = Mirror(reflecting: controller).children.first(where: { $0.label == name })?.value as? T else {
      fatalError("Missing production control: \(name)")
    }
    return value
  }
  func hasPendingTimer() -> Bool {
    guard let value = Mirror(reflecting: controller).children.first(where: { $0.label == "previewTimer" })?.value else { return false }
    return !Mirror(reflecting: value).children.isEmpty
  }
  func hasPreviewSnapshot() -> Bool {
    guard let value = Mirror(reflecting: controller).children.first(where: { $0.label == "previewSnapshot" })?.value else { return false }
    return !Mirror(reflecting: value).children.isEmpty
  }
  func timestamp(_ text: String) throws -> Double {
    let parts = text.split(separator: ":").map(String.init)
    guard (1...3).contains(parts.count), let seconds = Double(parts.last!) else {
      throw TestFailure(message: "The production field holds a parsable timestamp")
    }
    let minutes = parts.count >= 2 ? Double(parts[parts.count - 2]) ?? 0 : 0
    let hours = parts.count == 3 ? Double(parts[0]) ?? 0 : 0
    return hours * 3600 + minutes * 60 + seconds
  }
  let start = property("startField", NSTextField.self)
  let end = property("endField", NSTextField.self)
  let setStart = property("setStartButton", NSButton.self)
  let setEnd = property("setEndButton", NSButton.self)
  let preview = property("rangePreviewButton", NSButton.self)
  let mode = property("modeControl", NSSegmentedControl.self)
  let previewState = property("previewStatusLabel", NSTextField.self)

  try until("The production tools window is active, key, attached, and laid out") {
    controller.view.layoutSubtreeIfNeeded()
    return application.isActive && panel.isVisible && panel.isKeyWindow &&
      parent.appearanceUpdates > 0 &&
      controller.view.window === panel && start.window === panel && end.window === panel &&
      start.bounds.width > 0 && end.bounds.width > 0
  }

  @discardableResult
  func edit(_ field: NSTextField, _ value: String) throws -> TimeInterval {
    field.scrollToVisible(field.bounds)
    panel.makeKeyAndOrderFront(nil)
    field.selectText(nil)
    guard let editor = field.currentEditor() as? NSTextView else {
      throw TestFailure(message: "AppKit supplies the actual NSTextView field editor")
    }
    editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
    let changedAt = LiveClock.now
    editor.insertText(value, replacementRange: editor.selectedRange())
    try check(editor.string == value && field.stringValue == value, "Native field-editor insertion updates the production text field")
    // Do not synthesize delegate notifications or end editing: this is the real input path.
    return changedAt
  }
  func action(_ control: NSControl) throws {
    try check(control.isEnabled, "The native action is enabled")
    guard let selector = control.action else { throw TestFailure(message: "Missing native action") }
    try check(control.sendAction(selector, to: control.target), "Native sendAction reaches the production target")
  }
  func reset(position: Double = 0.25) throws {
    panel.makeFirstResponder(nil)
    controller.stopPreview()
    controller.setPlaybackControlsVisible(true)
    player.videoToolsClearLoop()
    player.pause()
    let restarts = mpv.restartEvents
    player.seek(absoluteSecond: position)
    try until("The real decoder finishes the paused setup seek") {
      mpv.restartEvents > restarts && !mpv.getFlag("seeking") &&
        mpv.getFlag(MPVOption.PlaybackControl.pause) &&
        abs(mpv.getDouble(MPVProperty.timePos) - position) < 0.12
    }
  }
  func setupFields(_ a: Double, _ b: Double) throws {
    try edit(start, String(format: "%.6f", a))
    try edit(end, String(format: "%.6f", b))
    controller.stopPreview()
  }
  func waitForRange(_ a: Double, _ b: Double) throws {
    try until("Debounced preview installs the requested real A-B range and unpauses") {
      guard let range = player.videoToolsLoopRange else { return false }
      return abs(range.start - a) < 0.002 && abs(range.end - b) < 0.002 &&
        !mpv.getFlag(MPVOption.PlaybackControl.pause) && !mpv.getFlag("seeking") &&
        range.contains(mpv.getDouble(MPVProperty.timePos))
    }
  }
  func proveMotion(timeout: Double = 3) throws {
    try until("Motion sampling starts after the real decoder seek has settled") {
      !mpv.getFlag("seeking") && !mpv.getFlag(MPVOption.PlaybackControl.pause)
    }
    var minimum = mpv.getDouble(MPVProperty.timePos)
    var maximum = minimum
    var hashes: Set<UInt64> = [clip_renderer_hash()]
    let frames = clip_renderer_frames()
    let deadline = LiveClock.now + timeout
    let requiresPixelChange = CommandLine.arguments.contains("--synthetic")
    repeat {
      pump(0.025)
      let position = mpv.getDouble(MPVProperty.timePos)
      minimum = min(minimum, position)
      maximum = max(maximum, position)
      hashes.insert(clip_renderer_hash())
      if maximum - minimum > 0.06 && clip_renderer_frames() > frames + 1 &&
          (!requiresPixelChange || hashes.count > 1) { break }
    } while LiveClock.now < deadline && mpv.error == nil
    let spread = maximum - minimum
    if spread <= 0.06 {
      print("DIAGNOSTIC: position spread=\(spread); current=\(mpv.getDouble(MPVProperty.timePos)); paused=\(mpv.getFlag(MPVOption.PlaybackControl.pause)); seeking=\(mpv.getFlag("seeking")); recovery=\(player.videoToolsLoopRecovery); frames=\(clip_renderer_frames() - frames)")
    }
    try check(spread > 0.06, "Real decoder playback time advances after preview")
    try check(clip_renderer_frames() > frames + 1, "Real libmpv delivers multiple rendered video frames")
    if requiresPixelChange {
      try check(hashes.count > 1, "Rendered RGB pixels change for the moving synthetic source")
    } else {
      print("EVIDENCE: external rendered pixel variants=\(hashes.count); static source frames are permitted")
    }
  }

  let cases: [(String, () throws -> Void)] = [
    ("opening", {
      try waitForRange(0, 5)
      try proveMotion()
      try action(preview)
      try until("Stopping the first automatic preview restores paused playback") {
        !mpv.getFlag("seeking") && mpv.getFlag(MPVOption.PlaybackControl.pause) && player.videoToolsLoopRange == nil
      }
      controller.setPlaybackControlsVisible(true)
      controller.refreshCurrentMedia()
      pump(0.65)
      try check(player.videoToolsLoopRange == nil && mpv.getFlag(MPVOption.PlaybackControl.pause) && !hasPendingTimer(),
                "Repeated visible and media refresh callbacks preserve a manual preview stop")
      mode.selectedSegment = 3
      try action(mode)
      pump(0.45)
      try check(player.videoToolsLoopRange == nil && mpv.getFlag(MPVOption.PlaybackControl.pause),
                "The conversion tab does not start preview")
      mode.selectedSegment = 0
      try action(mode)
      let reopenedStart = try timestamp(start.stringValue)
      let reopenedEnd = try timestamp(end.stringValue)
      try check(abs(reopenedEnd - reopenedStart - 5) < 0.001 && abs(reopenedStart - mpv.getDouble(MPVProperty.timePos)) < 0.12,
                "Returning to the clip tab anchors an untouched range at the current playback position")
      try waitForRange(reopenedStart, reopenedEnd)
      try proveMotion()
      player.pause()
      try until("A paused real decoder is not labelled as playing a preview") {
        previewState.stringValue == String(format: NSLocalizedString("videotools.preview.paused", comment: "Paused preview"),
                                          "00:00.000", "00:05.000")
      }
      // Removing/reinserting the parent matches the actual settings sidebar's
      // view lifecycle, using its extracted production appearance callbacks.
      parent.view.removeFromSuperview()
      try until("Removing the actual parent view cancels preview and restores the original state") {
        !hasPendingTimer() && player.videoToolsLoopRange == nil && mpv.getFlag(MPVOption.PlaybackControl.pause)
      }
      let appearanceCount = parent.appearanceUpdates
      panel.contentViewController = nil
      panel.contentViewController = parent
      parent.view.frame = panel.contentView!.bounds
      try until("Reinserting the parent executes the real tools appearance callback") {
        parent.appearanceUpdates > appearanceCount
      }
      try waitForRange(try timestamp(start.stringValue), try timestamp(end.stringValue))
      try proveMotion()
      controller.stopPreview()
    }),
    ("editing", {
      try reset()
      try edit(start, "0.800000")
      controller.stopPreview()
      try until("Debounce measurement begins with no previous preview or seek in flight") {
        !hasPendingTimer() && player.videoToolsLoopRange == nil && !mpv.getFlag("seeking") &&
          mpv.getFlag(MPVOption.PlaybackControl.pause)
      }
      var commands: [LivePlaybackCommand] = []
      mpv.playbackCommandObserver = { commands.append($0) }
      defer { mpv.playbackCommandObserver = nil }
      let lastChange = try edit(end, "1.500000")
      if runLoopStall > 0 {
        print("DIAGNOSTIC: blocking the fixture main thread for \(runLoopStall) seconds before timer delivery")
        Thread.sleep(forTimeInterval: runLoopStall)
      }
      try waitForRange(0.8, 1.5)
      mpv.playbackCommandObserver = nil
      // Inspect actual submission times, not the time a busy run loop returns
      // from a nominally short pump. A previous preview is explicitly stopped
      // above so its legitimate loop recovery cannot pollute this measurement.
      try check(commands.allSatisfy { command in
        command.submittedAt - lastChange >= 0.35
      }, "No actual seek or unpause is submitted before the full 350 ms debounce")
      try check(commands.contains { $0.kind == .seek && $0.submittedAt >= lastChange + 0.35 } &&
                commands.contains { $0.kind == .unpause && $0.submittedAt >= lastChange + 0.35 },
                "The final native edit submits both seek and unpause after its full debounce")
      print(String(format: "DEBOUNCE: first seek %.6f s; first unpause %.6f s",
                   commands.first(where: { $0.kind == .seek })!.submittedAt - lastChange,
                   commands.first(where: { $0.kind == .unpause })!.submittedAt - lastChange))
      try check(panel.firstResponder === start.currentEditor() || panel.firstResponder === end.currentEditor(),
                "Preview starts while the native field editor still owns focus")
      try proveMotion()
      var wraps = 0
      var last = mpv.getDouble(MPVProperty.timePos)
      let deadline = LiveClock.now + 3
      while wraps == 0 && LiveClock.now < deadline {
        pump(0.018)
        let now = mpv.getDouble(MPVProperty.timePos)
        if now < last - 0.2 { wraps += 1 }
        last = now
      }
      try check(wraps >= 1 && !mpv.getFlag(MPVOption.PlaybackControl.pause), "Real playback loops at B and continues from A")
      try edit(end, "2.400000")
      try edit(start, "1.700000")
      try waitForRange(1.7, 2.4)
      try proveMotion()
      try action(preview)
      try until("Stopping preview restores the original paused playback position") {
        !mpv.getFlag("seeking") && mpv.getFlag(MPVOption.PlaybackControl.pause) &&
          abs(mpv.getDouble(MPVProperty.timePos) - 0.25) < 0.12
      }
    }),
    ("marker-start", {
      try reset(position: 1)
      try setupFields(0.5, 3)
      let marker = player.videoToolsCurrentTime ?? 0
      try action(setStart)
      try waitForRange(marker, 3)
      try proveMotion()
    }),
    ("marker-end", {
      try reset(position: 1.8)
      try setupFields(0.5, 4)
      let marker = player.videoToolsCurrentTime ?? 0
      try action(setEnd)
      try waitForRange(0.5, marker)
      try proveMotion()
    }),
    ("navigation", {
      try reset()
      try edit(start, "0.600000")
      try edit(end, "1.300000")
      try waitForRange(0.6, 1.3)
      let navigation = property("playbackControl", NSSegmentedControl.self)
      // AppKit's momentary cell discards programmatic selection outside mouse
      // tracking. Retain the selected segment only for in-process sendAction.
      let trackingMode = navigation.trackingMode
      navigation.trackingMode = .selectOne
      defer { navigation.trackingMode = trackingMode }
      navigation.selectedSegment = 2
      try check(navigation.selectedSegment == 2, "The forward segment is selected before native dispatch")
      try action(navigation)
      try until("Native forward navigation settles beyond the temporary preview endpoint") {
        !mpv.getFlag("seeking") && (player.videoToolsCurrentTime ?? 0) > 4
      }
      player.pause()
      let newEnd = player.videoToolsCurrentTime ?? 0
      if newEnd <= 4 {
        print("DIAGNOSTIC: native navigation position=\(newEnd); A=\(mpv.getString(MPVOption.PlaybackControl.abLoopA) ?? "nil"); B=\(mpv.getString(MPVOption.PlaybackControl.abLoopB) ?? "nil"); count=\(mpv.getString(MPVOption.PlaybackControl.abLoopCount) ?? "nil"); seeking=\(mpv.getFlag("seeking"))")
      }
      try check(newEnd > 4, "Native forward navigation can extend beyond the temporary preview endpoint")
      try action(setEnd)
      try waitForRange(0.6, newEnd)
      try proveMotion()
    }),
    ("boundary", {
      try reset()
      mpv.rawCommand(["seek", String(duration + 1), "absolute+exact"])
      mpv.setFlag(MPVOption.PlaybackControl.pause, false)
      try until("The real player reaches EOF before editing") { mpv.getFlag(MPVProperty.eofReached) }
      try edit(start, String(format: "%.6f", duration - 1.5))
      try edit(end, String(format: "%.6f", duration + 0.0005))
      try waitForRange(duration - 1.5, duration)
      try check(abs((player.videoToolsLoopRange?.end ?? 0) - duration) < 0.000_001,
                "A tolerated rounded endpoint is normalized to the exact real duration")
      try proveMotion()
    }),
    ("precision", {
      // The file and decoder stay real. Only duration metadata is deliberately
      // varied to exercise sub-microsecond EOF values without private fixtures.
      defer { player.info.videoDuration = VideoTime(duration) }
      for fractionalDuration in [5.1234567, 119.9999997] {
        try reset()
        player.info.videoDuration = VideoTime(fractionalDuration)
        try edit(start, "1.000000")
        try edit(end, String(format: "%.6f", fractionalDuration))
        try waitForRange(1, fractionalDuration)
        let stored = mpv.getDouble(MPVOption.PlaybackControl.abLoopB)
        let stringValue = Double(mpv.getString(MPVOption.PlaybackControl.abLoopB) ?? "")
        try check(abs(stored - fractionalDuration) < 1e-9 && stringValue != stored,
                  "Real libmpv preserves fractional markers that its string representation rounds")
        try check(abs((player.videoToolsLoopRange?.end ?? 0) - fractionalDuration) < 1e-9,
                  "The production loop reader keeps full-precision EOF markers")
        guard let snapshot = player.videoToolsCaptureSnapshot() else {
          throw TestFailure(message: "The real player creates a preview snapshot")
        }
        player.videoToolsClearLoop()
        player.videoToolsRestoreSnapshot(snapshot)
        try check(abs(mpv.getDouble(MPVOption.PlaybackControl.abLoopB) - fractionalDuration) < 1e-9,
                  "Snapshot restoration keeps the exact fractional A-B marker")
        try proveMotion()
        controller.stopPreview()
      }
    }),
    ("invalid", {
      try reset()
      let commands = mpv.seekCommands
      try edit(start, "0.800000")
      try edit(end, "1.600000")
      // Cancel in the same native input turn. Yielding for an assumed short
      // interval could actually let the timer fire first on a loaded CI host.
      try edit(end, "invalid")
      pump(0.5)
      try check(mpv.seekCommands == commands && mpv.getFlag(MPVOption.PlaybackControl.pause),
                "Invalid input cancels delayed playback without any seek or unpause")
      try check(!hasPendingTimer(), "Invalid input clears the scheduled-preview token and pending UI state")
      try edit(end, "1.600000")
      try waitForRange(0.8, 1.6)
      try edit(end, "0.100000")
      try until("An invalid active range ends the loop without restoring the saved position") {
        player.videoToolsLoopRange == nil && !mpv.getFlag(MPVOption.PlaybackControl.pause) &&
          hasPreviewSnapshot() && mpv.getDouble(MPVProperty.timePos) > 0.6
      }
      try check(previewState.stringValue == NSLocalizedString("videotools.preview.invalid", comment: "Invalid range"),
                "The status explains that the typed range is invalid while the picture keeps playing")
      try edit(end, "1.700000")
      try waitForRange(0.8, 1.7)
      try proveMotion()
      try action(preview)
      try until("Stopping after an invalid interlude still restores the original paused position") {
        !mpv.getFlag("seeking") && mpv.getFlag(MPVOption.PlaybackControl.pause) &&
          abs(mpv.getDouble(MPVProperty.timePos) - 0.25) < 0.12
      }
    }),
    ("fullwidth", {
      try reset()
      // Chinese input methods emit full-width digits and punctuation.
      try edit(start, "\u{FF10}\u{FF0E}\u{FF18}")
      try edit(end, "\u{FF11}\u{3002}\u{FF15}")
      try waitForRange(0.8, 1.5)
      try proveMotion()
      controller.stopPreview()
    }),
    ("chrome-autohide", {
      try reset()
      try edit(start, "0.700000")
      try edit(end, "1.400000")
      try waitForRange(0.7, 1.4)
      try proveMotion()
      panel.makeFirstResponder(nil)
      // The edge-controls chrome hides the whole sidebar once the pointer rests on the
      // video. AppKit reports that hidden ancestor as a disappearance of the real parent
      // although it stays attached to its window and the settings sidebar stays open.
      player.mainWindow.sideBarStatus = .settings
      player.mainWindow.sidebarAutoHidden = true
      let disappearances = parent.disappearances
      let appearances = parent.appearanceUpdates
      parent.view.isHidden = true
      try until("Hiding the attached parent with the player chrome runs the real disappearance callback") {
        parent.disappearances > disappearances
      }
      pump(0.6)
      func previewKeepsRunning(_ label: String) -> Bool {
        let healthy = player.videoToolsLoopRange == VideoToolsLoopRange(start: 0.7, end: 1.4) &&
          !mpv.getFlag(MPVOption.PlaybackControl.pause) && !hasPendingTimer() && hasPreviewSnapshot()
        if !healthy {
          print("DIAGNOSTIC[\(label)]: range=\(String(describing: player.videoToolsLoopRange)); paused=\(mpv.getFlag(MPVOption.PlaybackControl.pause)); seeking=\(mpv.getFlag("seeking")); pendingTimer=\(hasPendingTimer()); snapshot=\(hasPreviewSnapshot()); position=\(mpv.getDouble(MPVProperty.timePos)); recovery=\(player.videoToolsLoopRecovery); disappearances=\(parent.disappearances); appearances=\(parent.appearanceUpdates); hidden=\(parent.view.isHidden); window=\(parent.view.window != nil); status=\(player.mainWindow.sideBarStatus)")
        }
        return healthy
      }
      func proveMotionWhileHidden(_ label: String) throws {
        // Record the real seeking/pause timeline so a settle timeout is diagnosable.
        let started = LiveClock.now
        var timeline: [String] = []
        while LiveClock.now < started + 3 {
          let seeking = mpv.getFlag("seeking")
          let paused = mpv.getFlag(MPVOption.PlaybackControl.pause)
          timeline.append(String(format: "%.2f%@%@@%.3f", LiveClock.now - started, seeking ? "S" : "-",
                                 paused ? "P" : "-", mpv.getDouble(MPVProperty.timePos)))
          if !seeking && !paused { break }
          pump(0.015)
        }
        if let last = timeline.last, last.contains("S") || last.contains("P") {
          print("DIAGNOSTIC[\(label)] settle timeline: \(timeline.suffix(60).joined(separator: " "))")
          print("DIAGNOSTIC[\(label)] restarts=\(mpv.restartEvents) seekCommands=\(mpv.seekCommands) eof=\(mpv.getFlag(MPVProperty.eofReached)) recovery=\(player.videoToolsLoopRecovery) abA=\(mpv.getString(MPVOption.PlaybackControl.abLoopA) ?? "nil") abB=\(mpv.getString(MPVOption.PlaybackControl.abLoopB) ?? "nil") count=\(mpv.getString(MPVOption.PlaybackControl.abLoopCount) ?? "nil")")
        }
        do { try proveMotion() } catch {
          _ = previewKeepsRunning(label)
          throw error
        }
      }
      try check(previewKeepsRunning("after-hide"), "Auto-hidden player chrome keeps the temporary preview range playing")
      try proveMotionWhileHidden("after-hide-motion")
      player.mainWindow.sidebarAutoHidden = false
      parent.view.isHidden = false
      try until("Revealing the player chrome runs the real appearance callback") {
        parent.appearanceUpdates > appearances
      }
      pump(0.6)
      try check(previewKeepsRunning("after-unhide"), "Revealing the player chrome neither restarts nor interrupts the running preview")
      try proveMotionWhileHidden("after-unhide-motion")
      // Closing the sidebar changes its status before the view detaches and then notifies
      // the panel, matching hideSideBar. That real close still ends the preview and
      // restores the saved paused position.
      player.mainWindow.sideBarStatus = .hidden
      parent.view.removeFromSuperview()
      parent.sidebarDidClose()
      try until("Closing the sidebar still cancels the preview and restores the paused position") {
        !hasPendingTimer() && !hasPreviewSnapshot() && player.videoToolsLoopRange == nil &&
          !mpv.getFlag("seeking") && mpv.getFlag(MPVOption.PlaybackControl.pause) &&
          abs(mpv.getDouble(MPVProperty.timePos) - 0.25) < 0.12
      }
      func reattachParent(_ message: String) throws {
        let reattached = parent.appearanceUpdates
        panel.contentViewController = nil
        panel.contentViewController = parent
        parent.view.frame = panel.contentView!.bounds
        player.mainWindow.sideBarStatus = .settings
        try until(message) { parent.appearanceUpdates > reattached }
      }
      try reattachParent("Reinserting the parent after a close executes the real appearance callback")
      // The window can close, or a keyboard shortcut can close the sidebar, while the
      // chrome still hides it. AppKit sends no second disappearance then, so the explicit
      // close must end the preview and the later media reload must not revive it.
      try waitForRange(0.7, 1.4)
      try proveMotion()
      player.mainWindow.sidebarAutoHidden = true
      parent.view.isHidden = true
      pump(0.3)
      try check(previewKeepsRunning("before-hidden-close"), "The preview is still running when the hidden sidebar closes")
      player.mainWindow.sidebarAutoHidden = false
      player.mainWindow.sideBarStatus = .hidden
      parent.view.removeFromSuperview()
      parent.sidebarDidClose()
      try until("Closing the sidebar while the chrome hides it still cancels the preview") {
        !hasPendingTimer() && !hasPreviewSnapshot() && player.videoToolsLoopRange == nil &&
          !mpv.getFlag("seeking") && mpv.getFlag(MPVOption.PlaybackControl.pause) &&
          abs(mpv.getDouble(MPVProperty.timePos) - 0.25) < 0.12
      }
      controller.refreshCurrentMedia(force: true)
      pump(0.65)
      try check(!hasPendingTimer() && !hasPreviewSnapshot() && player.videoToolsLoopRange == nil &&
                mpv.getFlag(MPVOption.PlaybackControl.pause),
                "A media reload after a hidden close does not revive the automatic preview")
      parent.view.isHidden = false
      try reattachParent("Reinserting the parent after a hidden close executes the real appearance callback")
      controller.stopPreview()
    }),
    ("media-reload", {
      try reset()
      // Mirror the real application's load sequence: the main window's own file-loaded
      // observer reloads the visible tools tab first, then the panel's observer forces a
      // refresh of the now-unchanged source. The automatic preview must survive both.
      player.videoToolsMediaGeneration &+= 1
      controller.refreshCurrentMedia()
      try check(hasPendingTimer(), "The reloaded tools tab schedules the automatic preview for the new media")
      controller.refreshCurrentMedia(force: true)
      let defaultStart = try timestamp(start.stringValue)
      let defaultEnd = try timestamp(end.stringValue)
      try check(defaultEnd - defaultStart > 4.9 && defaultEnd - defaultStart < 5.1,
                "The reloaded media keeps its default five-second range")
      try check(hasPendingTimer(), "The forced refresh of the unchanged source keeps the scheduled automatic preview")
      try waitForRange(defaultStart, defaultEnd)
      try proveMotion()
      controller.stopPreview()
    }),
    ("landing", {
      try reset()
      // The synthetic 30000/1001 fps source has frame 1 at 0.0333666… s. A marker captured
      // from time-pos rounds it up to 0.033367, and mpv's exact seek then displays that frame
      // 0.3 µs before the request. Recovery must accept the landing instead of suspending.
      try edit(start, "0.033367")
      try edit(end, "0.900000")
      try waitForRange(0.033367, 0.9)
      try proveMotion()
      player.pause()
      let restarts = mpv.restartEvents
      player.seek(absoluteSecond: 0.033367)
      try until("The paused seek to the rounded marker settles on the real decoder frame") {
        mpv.restartEvents > restarts && !mpv.getFlag("seeking") && mpv.getFlag(MPVOption.PlaybackControl.pause)
      }
      pump(0.8)
      let landed = mpv.getDouble(MPVProperty.timePos)
      print(String(format: "LANDING: marker=0.033367 time-pos=%.9f recovery=%@", landed,
                   String(describing: player.videoToolsLoopRecovery)))
      try check(landed > 0.03 && landed < 0.0339, "mpv displays the frame at the requested marker")
      try check(!player.videoToolsLoopRecovery.suspended && player.videoToolsLoopRecovery.failures == 0,
                "A landing microseconds before the marker is accepted without corrections")
      player.resume()
      try until("Resuming after the paused landing plays the loop") { !mpv.getFlag(MPVOption.PlaybackControl.pause) }
      try proveMotion()
      controller.stopPreview()
    }),
    ("anchor", {
      try reset()
      // The file-loaded refresh records the range at the load position. Revealing the clip
      // tab later must re-anchor an untouched range to where the user is actually watching.
      controller.setPlaybackControlsVisible(false)
      player.videoToolsMediaGeneration &+= 1
      controller.refreshCurrentMedia(force: true)
      let loadedStart = try timestamp(start.stringValue)
      try check(abs(loadedStart - 0.25) < 0.12, "The file-loaded refresh records the load position as the default start")
      let restarts = mpv.restartEvents
      player.seek(absoluteSecond: 2)
      try until("The real decoder settles on the later viewing position") {
        mpv.restartEvents > restarts && !mpv.getFlag("seeking") && abs(mpv.getDouble(MPVProperty.timePos) - 2) < 0.12
      }
      controller.setPlaybackControlsVisible(true)
      let anchoredStart = try timestamp(start.stringValue)
      let anchoredEnd = try timestamp(end.stringValue)
      try check(abs(anchoredStart - 2) < 0.12 && abs(anchoredEnd - anchoredStart - 5) < 0.001,
                "Revealing the clip tab anchors the untouched default range at the current position")
      try waitForRange(anchoredStart, anchoredEnd)
      try proveMotion()
      controller.stopPreview()
    }),
    ("restore", {
      try reset(position: 0.4)
      mpv.setString(MPVOption.PlaybackControl.abLoopA, "no")
      mpv.setString(MPVOption.PlaybackControl.abLoopB, "no")
      mpv.setString(MPVOption.PlaybackControl.abLoopCount, "0")
      mpv.setInt(MPVOption.Video.videoRotate, 180)
      try edit(start, "1.000000")
      try edit(end, "1.800000")
      try waitForRange(1, 1.8)
      // Match QuickSettingViewController's production disappearance sequence.
      controller.setPlaybackControlsVisible(false)
      controller.stopPreview()
      panel.orderOut(nil)
      try until("Hiding tools restores the original paused position") {
        !mpv.getFlag("seeking") && mpv.getFlag(MPVOption.PlaybackControl.pause) &&
          abs(mpv.getDouble(MPVProperty.timePos) - 0.4) < 0.12
      }
      try check(mpv.getString(MPVOption.PlaybackControl.abLoopA) == "no" &&
                mpv.getString(MPVOption.PlaybackControl.abLoopB) == "no" &&
                mpv.getString(MPVOption.PlaybackControl.abLoopCount) == "0" &&
                mpv.getInt(MPVOption.Video.videoRotate) == 180,
                "Hiding tools restores unset A-B markers, loop count, and rotation")
      panel.makeKeyAndOrderFront(nil)
      application.activate(ignoringOtherApps: true)
      controller.setPlaybackControlsVisible(true)
      try until("The tools window becomes key again before resumed native editing") { panel.isKeyWindow && panel.isVisible }
      try edit(start, "1.100000")
      try waitForRange(1.1, 1.8)
      try proveMotion()
      controller.stopPreview()
      mpv.setInt(MPVOption.Video.videoRotate, 0)
      player.videoToolsClearLoop()
      mpv.setDouble(MPVOption.PlaybackControl.abLoopA, 0)
      mpv.setDouble(MPVOption.PlaybackControl.abLoopB, 4)
      mpv.setString(MPVOption.PlaybackControl.abLoopCount, "inf")
      player.resume()
      try until("Original A-B playback is running before replacement preview") {
        !mpv.getFlag("seeking") && !mpv.getFlag(MPVOption.PlaybackControl.pause)
      }
      try edit(start, "1.100000")
      try edit(end, "1.900000")
      try waitForRange(1.1, 1.9)
      controller.setPlaybackControlsVisible(false)
      controller.stopPreview()
      try until("An existing zero-start A-B loop and originally playing state survive preview restoration") {
        !mpv.getFlag("seeking") && player.videoToolsLoopRange == VideoToolsLoopRange(start: 0, end: 4) &&
          !mpv.getFlag(MPVOption.PlaybackControl.pause)
      }
      try proveMotion()
    }),
  ]
  let selected = argument("--case") ?? "all"
  for (name, body) in cases where selected == "all" || selected == name || (selected == "markers" && name.hasPrefix("marker-")) {
    print("CASE: \(name)")
    do { try body() }
    catch let error as TestFailure { failures += 1; print("FAIL [\(name)]: \(error.message)") }
    catch { failures += 1; print("FAIL [\(name)]: unexpected test error") }
  }
  try check(mpv.error == nil, mpv.error ?? "No real decoder, property, command, or renderer errors occurred")
  print("SUMMARY: \(assertions) assertions passed; \(failures) cases failed; rendered frames=\(clip_renderer_frames())")
}

do { try run() }
catch let error as TestFailure { failures += 1; print("FAIL: \(error.message)") }
catch { failures += 1; print("FAIL: unexpected live test error") }
exit(failures == 0 ? 0 : 1)
