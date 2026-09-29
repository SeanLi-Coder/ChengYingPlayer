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
  let player = PlayerCore()
  let mpv = player.mpv
  let media = URL(fileURLWithPath: path)
  player.info.currentURL = media
  mpv.rawCommand(["loadfile", media.path, "replace"])

  func pump(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
      player.processEvents()
      while let event = application.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
        application.sendEvent(event)
      }
      application.updateWindows()
      RunLoop.main.run(until: Date().addingTimeInterval(0.003))
    } while Date() < deadline && mpv.error == nil
  }
  func until(_ message: String, timeout: Double = 3, _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline, mpv.error == nil { pump(0.015) }
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
  let panel = NSWindow(contentRect: NSRect(x: 750, y: 120, width: 380, height: 850),
                       styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
  panel.isReleasedWhenClosed = false
  panel.title = "Clip Preview Live Test - Production Controls"
  panel.contentViewController = controller
  panel.makeKeyAndOrderFront(nil)
  application.activate(ignoringOtherApps: true)
  controller.setPlaybackControlsVisible(true)
  controller.view.layoutSubtreeIfNeeded()
  pump(0.1)
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
  let start = property("startField", NSTextField.self)
  let end = property("endField", NSTextField.self)
  let setStart = property("setStartButton", NSButton.self)
  let setEnd = property("setEndButton", NSButton.self)
  let preview = property("rangePreviewButton", NSButton.self)

  func edit(_ field: NSTextField, _ value: String) throws {
    field.scrollToVisible(field.bounds)
    panel.makeKeyAndOrderFront(nil)
    field.selectText(nil)
    guard let editor = field.currentEditor() as? NSTextView else {
      throw TestFailure(message: "AppKit supplies the actual NSTextView field editor")
    }
    editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
    editor.insertText(value, replacementRange: editor.selectedRange())
    try check(editor.string == value && field.stringValue == value, "Native field-editor insertion updates the production text field")
    // Do not synthesize delegate notifications or end editing: this is the real input path.
  }
  func action(_ control: NSControl) throws {
    try check(control.isEnabled, "The native action is enabled")
    guard let selector = control.action else { throw TestFailure(message: "Missing native action") }
    try check(control.sendAction(selector, to: control.target), "Native sendAction reaches the production target")
  }
  func reset(position: Double = 0.25) {
    panel.makeFirstResponder(nil)
    controller.stopPreview()
    controller.setPlaybackControlsVisible(true)
    player.videoToolsClearLoop()
    player.pause()
    player.seek(absoluteSecond: position)
    pump(0.18)
  }
  func setupFields(_ a: Double, _ b: Double) throws {
    try edit(start, String(format: "%.6f", a))
    try edit(end, String(format: "%.6f", b))
    controller.stopPreview()
  }
  func waitForRange(_ a: Double, _ b: Double) throws {
    try until("Debounced preview installs the requested real A-B range and unpauses") {
      guard let range = player.videoToolsLoopRange else { return false }
      return abs(range.start - a) < 0.002 && abs(range.end - b) < 0.002 && !mpv.getFlag(MPVOption.PlaybackControl.pause)
    }
  }
  func proveMotion(_ seconds: Double = 0.3) throws {
    var positions: [Double] = []
    var hashes = Set<UInt64>()
    let frames = clip_renderer_frames()
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
      pump(0.025)
      positions.append(mpv.getDouble(MPVProperty.timePos))
      hashes.insert(clip_renderer_hash())
    } while Date() < deadline
    let spread = (positions.max() ?? 0) - (positions.min() ?? 0)
    if spread <= 0.06 {
      print("DIAGNOSTIC: position spread=\(spread); last=\(positions.last ?? -1); paused=\(mpv.getFlag(MPVOption.PlaybackControl.pause)); seeking=\(mpv.getFlag("seeking")); recovery=\(player.videoToolsLoopRecovery); frames=\(clip_renderer_frames() - frames)")
    }
    try check(spread > 0.06, "Real decoder playback time advances after preview")
    try check(clip_renderer_frames() > frames + 1, "Real libmpv delivers multiple rendered video frames")
    if CommandLine.arguments.contains("--synthetic") {
      try check(hashes.count > 1, "Rendered RGB pixels change for the moving synthetic source")
    } else {
      print("EVIDENCE: external rendered pixel variants=\(hashes.count); static source frames are permitted")
    }
  }

  let cases: [(String, () throws -> Void)] = [
    ("editing", {
      reset()
      let commands = mpv.seekCommands
      try edit(start, "0.800000")
      try edit(end, "1.500000")
      let changed = Date()
      pump(0.16)
      try check(mpv.seekCommands == commands && mpv.getFlag(MPVOption.PlaybackControl.pause),
                "Typing does not seek or unpause before the 350 ms debounce")
      try waitForRange(0.8, 1.5)
      try check(Date().timeIntervalSince(changed) >= 0.30, "Automatic preview respects the debounce interval")
      try check(panel.firstResponder === start.currentEditor() || panel.firstResponder === end.currentEditor(),
                "Preview starts while the native field editor still owns focus")
      try proveMotion()
      var wraps = 0
      var last = mpv.getDouble(MPVProperty.timePos)
      let deadline = Date().addingTimeInterval(1.65)
      while Date() < deadline {
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
      pump(0.18)
      try check(mpv.getFlag(MPVOption.PlaybackControl.pause) && abs(mpv.getDouble(MPVProperty.timePos) - 0.25) < 0.12,
                "Stopping preview restores the original paused playback position")
    }),
    ("marker-start", {
      reset(position: 1)
      try setupFields(0.5, 3)
      let marker = player.videoToolsCurrentTime ?? 0
      try action(setStart)
      try waitForRange(marker, 3)
      try proveMotion()
    }),
    ("marker-end", {
      reset(position: 1.8)
      try setupFields(0.5, 4)
      let marker = player.videoToolsCurrentTime ?? 0
      try action(setEnd)
      try waitForRange(0.5, marker)
      try proveMotion()
    }),
    ("navigation", {
      reset()
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
      pump(0.2)
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
      reset()
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
        reset()
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
      reset()
      let commands = mpv.seekCommands
      try edit(start, "0.800000")
      try edit(end, "1.600000")
      pump(0.08)
      try edit(end, "invalid")
      pump(0.5)
      try check(mpv.seekCommands == commands && mpv.getFlag(MPVOption.PlaybackControl.pause),
                "Invalid input cancels delayed playback without any seek or unpause")
      try check(!hasPendingTimer(), "Invalid input clears the scheduled-preview token and pending UI state")
      try edit(end, "1.600000")
      try waitForRange(0.8, 1.6)
      try edit(end, "0.100000")
      pump(0.4)
      try check(player.videoToolsLoopRange == nil && mpv.getFlag(MPVOption.PlaybackControl.pause),
                "An invalid active range restores the paused pre-preview state")
    }),
    ("restore", {
      reset(position: 0.4)
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
      pump(0.25)
      try check(mpv.getFlag(MPVOption.PlaybackControl.pause) && abs(mpv.getDouble(MPVProperty.timePos) - 0.4) < 0.12,
                "Hiding tools restores the original paused position")
      try check(mpv.getString(MPVOption.PlaybackControl.abLoopA) == "no" &&
                mpv.getString(MPVOption.PlaybackControl.abLoopB) == "no" &&
                mpv.getString(MPVOption.PlaybackControl.abLoopCount) == "0" &&
                mpv.getInt(MPVOption.Video.videoRotate) == 180,
                "Hiding tools restores unset A-B markers, loop count, and rotation")
      panel.makeKeyAndOrderFront(nil)
      controller.setPlaybackControlsVisible(true)
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
      pump(0.12)
      try edit(start, "1.100000")
      try edit(end, "1.900000")
      try waitForRange(1.1, 1.9)
      controller.setPlaybackControlsVisible(false)
      controller.stopPreview()
      pump(0.12)
      try check(player.videoToolsLoopRange == VideoToolsLoopRange(start: 0, end: 4) &&
                !mpv.getFlag(MPVOption.PlaybackControl.pause),
                "An existing zero-start A-B loop and originally playing state survive preview restoration")
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
