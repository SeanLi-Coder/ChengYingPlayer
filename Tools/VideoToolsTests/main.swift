import Cocoa
setbuf(stdout, nil)

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.finishLaunching()
let player = PlayerCore()
player.info.currentURL = URL(fileURLWithPath: #filePath)
let mainWindow = MainWindowController()
let controller = VideoToolsViewController(player: player, mainWindow: mainWindow)
let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
panel.contentViewController = controller
controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
controller.view.layoutSubtreeIfNeeded()
controller.viewDidLayout()

func property<T>(_ name: String, as: T.Type) -> T {
  guard let value = Mirror(reflecting: controller).children.first(where: { $0.label == name })?.value as? T else { fatalError("Missing property: \(name)") }
  return value
}
func action(_ control: NSControl) {
  guard let selector = control.action else { fatalError("Missing action") }
  _ = control.sendAction(selector, to: control.target)
  if let segmented = control as? NSSegmentedControl, segmented.trackingMode == .momentary {
    for index in 0..<segmented.segmentCount { segmented.setSelected(false, forSegment: index) }
  }
}
var passes = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  passes += 1
  print("PASS: \(message)")
}
func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_001 }
let playback = property("playbackControl", as: NSSegmentedControl.self)
let frames = property("frameStepControl", as: NSSegmentedControl.self)
let speeds = property("speedPopup", as: NSPopUpButton.self)
let start = property("startField", as: NSTextField.self)
let end = property("endField", as: NSTextField.self)
let setStart = property("setStartButton", as: NSButton.self)
let setEnd = property("setEndButton", as: NSButton.self)
let preview = property("rangePreviewButton", as: NSButton.self)
let previewStatus = property("previewStatusLabel", as: NSTextField.self)
let navigation = property("rangeNavigationControl", as: NSSegmentedControl.self)
let modes = property("modeControl", as: NSSegmentedControl.self)
let run = property("runButton", as: NSButton.self)
let frameFormat = property("frameFormatPopup", as: NSPopUpButton.self)
let frameFormatGroup = property("frameFormatGroup", as: NSStackView.self)
let frameFormatHint = property("frameFormatHintLabel", as: NSTextField.self)

// Exercise AppKit's real field editor while the production playback refresh runs.
// These cases never call the controller's text delegate or post change notifications.
func runAutomaticPreviewRegression(_ scenario: String) {
  let testPlayer = PlayerCore()
  testPlayer.info.currentURL = URL(fileURLWithPath: #filePath)
  let testMainWindow = MainWindowController()
  let testController = VideoToolsViewController(player: testPlayer, mainWindow: testMainWindow)
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 720),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
  window.contentViewController = testController
  window.makeKeyAndOrderFront(nil)
  application.activate(ignoringOtherApps: true)
  testController.setPlaybackControlsVisible(true)
  func field<T>(_ name: String, as: T.Type) -> T {
    Mirror(reflecting: testController).children.first(where: { $0.label == name })!.value as! T
  }
  let first = field("startField", as: NSTextField.self)
  let last = field("endField", as: NSTextField.self)
  let firstMarker = field("setStartButton", as: NSButton.self)
  let lastMarker = field("setEndButton", as: NSButton.self)
  let mode = field("modeControl", as: NSSegmentedControl.self)
  let previewState = field("previewStatusLabel", as: NSTextField.self)
  func text(_ key: String) -> String { NSLocalizedString(key, comment: "Automatic preview regression") }
  func pump(_ interval: TimeInterval = 0.45) { RunLoop.main.run(until: Date().addingTimeInterval(interval)) }
  var notifications = 0
  let observer = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification,
      object: nil, queue: .main) { note in
    if let sender = note.object as? NSTextField, sender === first || sender === last { notifications += 1 }
  }
  defer {
    testController.stopPreview()
    testController.setPlaybackControlsVisible(false)
    window.makeFirstResponder(nil)
    window.orderOut(nil)
    NotificationCenter.default.removeObserver(observer)
  }
  @discardableResult
  func type(_ value: String, into field: NSTextField) -> NSTextView {
    check(window.makeFirstResponder(field), "The real timestamp field accepts keyboard focus")
    guard let editor = field.currentEditor() as? NSTextView else { fatalError("Missing native field editor") }
    let before = notifications
    editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    check(notifications > before && field.stringValue == value,
          "Native field-editor insertion publishes the actual NSTextField change notification")
    return editor
  }
  func expectsRange(_ start: Double, _ end: Double, _ message: String) {
    check(testPlayer.videoToolsLoopRange == VideoToolsLoopRange(start: start, end: end) &&
          !testPlayer.mpv.getFlag("pause"), message)
  }
  first.stringValue = "10"
  last.stringValue = "20"
  testPlayer.pause()

  switch scenario {
  case "input":
    let editor = type("21.125", into: last)
    check(previewState.stringValue == text("videotools.preview.pending"), "Real text input schedules automatic preview")
    let reads = testPlayer.mpv.reads
    pump(0.22)
    check(testPlayer.mpv.reads > reads && window.firstResponder === editor && editor.string == "21.125",
          "The live 200 ms playback refresh preserves field-editor focus and uncommitted input")
    check(testPlayer.videoToolsLoopRange == nil, "Automatic preview waits for its debounce interval")
    type("22.5", into: last)
    pump(0.22)
    check(testPlayer.videoToolsLoopRange == nil, "Further native typing restarts the automatic preview deadline")
    pump(0.23)
    expectsRange(10, 22.5, "The latest uncommitted field-editor range starts automatically")
    check(window.firstResponder === editor && last.currentEditor() === editor,
          "Starting preview does not end editing or move keyboard focus")
    let startEditor = type("11.375", into: first)
    pump()
    expectsRange(11.375, 22.5, "A second edit updates an already active automatic preview")
    check(window.firstResponder === startEditor, "Repeated automatic preview preserves the currently edited field")
  case "markers":
    testPlayer.mpv.values["time"] = 11.123456
    action(firstMarker)
    check(testPlayer.mpv.getFlag("pause") && testPlayer.videoToolsLoopRange == nil,
          "The start marker pauses immediately while selecting its precise frame")
    pump(0.2)
    check(testPlayer.videoToolsLoopRange == nil, "The start marker uses the same debounce as typing")
    pump(0.25)
    expectsRange(11.123456, 20, "The start marker automatically previews after 350 ms")
    testPlayer.mpv.values["time"] = 17.654321
    action(lastMarker)
    check(testPlayer.mpv.getFlag("pause") && testPlayer.videoToolsLoopRange == nil && last.stringValue == "00:17.654321",
          "An end marker preserves the current frame and replaces the preceding preview")
    pump()
    expectsRange(11.123456, 17.654321, "The end marker automatically previews its updated interval")
    testPlayer.mpv.values["time"] = 12.25
    action(firstMarker)
    pump()
    expectsRange(12.25, 17.654321, "A later start marker updates automatic preview again")
    testPlayer.mpv.values["time"] = 11
    action(lastMarker)
    pump()
    check(testPlayer.videoToolsLoopRange == nil && previewState.stringValue == text("videotools.preview.invalid"),
          "An end marker before the start cancels automatic preview and explains the invalid range")
  case "rounding":
    for duration in [5.1234567, 119.9999997] {
      testController.stopPreview()
      testPlayer.mpv.values["time"] = 0.0
      testPlayer.info.videoDuration = VideoTime(duration)
      testController.refreshCurrentMedia(force: true)
      first.stringValue = "0"
      let rounded = String(format: "%.6f", duration)
      type(rounded, into: last)
      pump()
      expectsRange(0, duration, "A microsecond-rounded endpoint clamps to the real duration before preview")
      check(testPlayer.mpv.getDouble("b") == duration,
            "Automatic preview passes the exact finite duration to the strict player bridge")
      testController.stopPreview()
      action(field("runButton", as: NSButton.self))
      check(VideoToolsTaskManager.shared.request?.end == duration,
            "Export and automatic preview use the same normalized endpoint")
      mode.selectedSegment = 1; action(mode)
      let frameStart = duration < 10 ? 1.0 : 118.0
      type(String(format: "%.6f", frameStart), into: first)
      let displayedEnd = duration < 10 ? "00:0" + rounded : "02:00.000000"
      check(last.stringValue == displayedEnd, "Frame extraction displays its duration-clamped default endpoint")
      pump()
      expectsRange(frameStart, duration, "The default five-second extraction range previews at a rounded file end")
      mode.selectedSegment = 0; action(mode)
      type(rounded, into: first)
      type(String(format: "%.6f", duration + 0.0005), into: last)
      pump()
      check(testPlayer.videoToolsLoopRange == nil && previewState.stringValue == text("videotools.preview.invalid"),
            "Clamping cannot turn a nominally positive input range into a zero or negative bridge range")
    }
  case "invalid":
    type("21", into: last)
    check(previewState.stringValue == text("videotools.preview.pending"), "A valid edit starts a pending preview")
    type("bad", into: last)
    check(previewState.stringValue == text("videotools.preview.invalid"),
          "Invalid text clears the pending timer identity immediately")
    pump()
    check(testPlayer.videoToolsLoopRange == nil, "A cancelled pending preview never starts later")
    type("22", into: last)
    pump()
    expectsRange(10, 22, "Valid native input recovers after an invalid pending edit")
    for invalid in ["10", "9", "120.01", "nan"] {
      type(invalid, into: last)
      pump()
      check(testPlayer.videoToolsLoopRange == nil && previewState.stringValue == text("videotools.preview.invalid"),
            "Invalid endpoint \(invalid) cannot leave an old preview playing")
    }
  case "lifecycle":
    testPlayer.mpv.values["a"] = 3.0
    testPlayer.mpv.values["b"] = 7.0
    testPlayer.mpv.values["count"] = "inf"
    testPlayer.mpv.values["time"] = 5.0
    testPlayer.mpv.values["speed"] = 0.5
    type("16", into: last)
    pump()
    expectsRange(10, 16, "Native text temporarily previews over an existing keyboard loop")
    type("17", into: last)
    testController.setPlaybackControlsVisible(false)
    testController.stopPreview()
    window.makeFirstResponder(nil)
    window.orderOut(nil)
    pump()
    check(testPlayer.videoToolsLoopRange == VideoToolsLoopRange(start: 3, end: 7) &&
          testPlayer.mpv.getDouble("time") == 5 && testPlayer.mpv.getFlag("pause") && testPlayer.mpv.getDouble("speed") == 0.5,
          "Hiding the panel cancels pending edits and restores the original loop, position, pause and speed")
    window.makeKeyAndOrderFront(nil)
    testController.setPlaybackControlsVisible(true)
    pump()
    check(testPlayer.videoToolsLoopRange == VideoToolsLoopRange(start: 3, end: 7),
          "Showing the panel cannot revive a cancelled automatic preview")
    type("18", into: last)
    mode.selectedSegment = 2; action(mode)
    pump()
    check(testPlayer.videoToolsLoopRange == VideoToolsLoopRange(start: 3, end: 7),
          "Switching tabs cancels a pending range preview")
    mode.selectedSegment = 0; action(mode)
    type("19", into: last)
    pump()
    expectsRange(10, 19, "Returning to the clip tab accepts fresh automatic-preview edits")
    mode.selectedSegment = 1; action(mode)
    check(testPlayer.videoToolsLoopRange == VideoToolsLoopRange(start: 3, end: 7),
          "Switching tabs restores the snapshot of an active automatic preview")
    type("11.25", into: first)
    check(last.stringValue == "00:16.250000", "Real frame-mode typing updates the default five-second endpoint")
    pump()
    expectsRange(11.25, 16.25, "The default five-second frame range previews automatically")
  case "navigation":
    let seekControl = field("playbackControl", as: NSSegmentedControl.self)
    let frameControl = field("frameStepControl", as: NSSegmentedControl.self)
    let boundaryControl = field("rangeNavigationControl", as: NSSegmentedControl.self)
    for control in [seekControl, frameControl, boundaryControl] { control.trackingMode = .selectOne }
    type("15", into: last)
    pump()
    expectsRange(10, 15, "A temporary preview is active before selecting a later endpoint")
    testPlayer.mpv.values["time"] = 14.0
    seekControl.selectedSegment = 2; action(seekControl)
    check(testPlayer.videoToolsLoopRange == nil && near(testPlayer.mpv.getDouble("time"), 19),
          "Forward navigation leaves the temporary preview and can move beyond its end")
    action(lastMarker)
    pump()
    expectsRange(10, 19, "Marking the later endpoint automatically previews the extended range")
    testPlayer.mpv.values["time"] = 18.9995
    frameControl.selectedSegment = 1; action(frameControl)
    check(testPlayer.videoToolsLoopRange == nil && testPlayer.mpv.getDouble("time") > 19 && testPlayer.mpv.getFlag("pause"),
          "Frame stepping leaves the temporary range while preserving the newly selected frame")
    action(lastMarker)
    pump()
    expectsRange(10, 19.032833, "A frame-selected endpoint can expand the next automatic preview")
    type("25", into: last)
    boundaryControl.selectedSegment = 1; action(boundaryControl)
    pump()
    check(testPlayer.videoToolsLoopRange == nil && testPlayer.mpv.getDouble("time") == 25 && testPlayer.mpv.getFlag("pause"),
          "Explicit boundary navigation cancels the pending preview and reaches the edited endpoint")
    testPlayer.mpv.values["time"] = 3.0
    check(testController.setLoopMarker(isEnd: false), "The independent keyboard loop accepts a new A marker")
    testPlayer.mpv.values["time"] = 7.0
    check(testController.setLoopMarker(isEnd: true), "The independent keyboard loop accepts a new B marker")
    first.stringValue = "10"
    type("15", into: last)
    pump()
    expectsRange(10, 15, "Temporary preview can coexist with the saved independent keyboard loop")
    testPlayer.mpv.values["time"] = 14.0
    seekControl.selectedSegment = 2; action(seekControl)
    check(testPlayer.videoToolsLoopRange == VideoToolsLoopRange(start: 3, end: 7) &&
          testPlayer.mpv.getDouble("time") >= 3 && testPlayer.mpv.getDouble("time") < 7,
          "Leaving temporary preview restores the independent keyboard loop and retains its seek limits")
  default: fatalError("Unknown preview regression scenario")
  }
}

let previewRegressionCase = ProcessInfo.processInfo.environment["CHENGYING_PREVIEW_REGRESSION_CASE"]
for scenario in previewRegressionCase.map({ [$0] }) ?? ["input", "markers", "rounding", "invalid", "lifecycle", "navigation"] {
  runAutomaticPreviewRegression(scenario)
}
if previewRegressionCase != nil {
  print("SUCCESS: \(passes) automatic-preview UI checks passed using playback stubs")
  exit(0)
}

check(frameFormat.numberOfItems == 2 && frameFormat.indexOfSelectedItem == 0,
      "A fresh frame extraction panel defaults to JPG and retains a lossless option")
check(frameFormatGroup.isHidden && frameFormatHint.stringValue == NSLocalizedString("videotools.frames.hint.jpg", comment: ""),
      "Frame format is scoped to extraction and explains lossy JPEG quality")
let faster = property("fasterButton", as: NSButton.self)
let slower = property("slowerButton", as: NSButton.self)
let mediaInfo = property("mediaInfoButton", as: NSButton.self)
check(mediaInfo.title == mediaInfoText("action.info", "Info") && mediaInfo.isEnabled,
      "The local video information entry is localized and enabled")
let mediaInfoRect = controller.view.convert(mediaInfo.bounds, from: mediaInfo)
check(mediaInfoRect.minX >= 0 && mediaInfoRect.maxX <= 320 && mediaInfoRect.width < 100,
      "The information entry stays compact inside the narrow native sidebar")
let toolsScroll = controller.view.subviews.compactMap { $0 as? NSScrollView }.first!
let taskStatus = property("statusLabel", as: NSTextField.self)
let originalTaskStatus = taskStatus.stringValue
let syntheticFailure = Array(repeating: "Export failed: a detailed diagnostic remains fully scrollable.", count: 12).joined(separator: "\n")
func layoutTools(width: CGFloat = 320, height: CGFloat) {
  panel.setContentSize(NSSize(width: width, height: height))
  controller.view.needsLayout = true
  controller.view.layoutSubtreeIfNeeded()
  controller.viewDidLayout()
  controller.view.layoutSubtreeIfNeeded()
}
for width: CGFloat in [320, 360] {
for height: CGFloat in [240, 300, 350, 400, 600] {
  taskStatus.stringValue = syntheticFailure
  layoutTools(width: width, height: height)
  check(toolsScroll.bounds.height > 90, "A long failure leaves a usable scroll viewport at height \(height)")
  for control in [preview as NSView, previewStatus, run] {
    let frame = controller.view.convert(control.bounds, from: control)
    check(frame.minX >= 0 && frame.maxX <= width && frame.minY >= 0 && frame.maxY <= height && frame.height > 0,
          "Preview, its status, and confirmation remain visible at height \(height)")
    check(!control.isDescendant(of: toolsScroll), "Essential actions are not hidden inside scrolling content")
  }
  check(taskStatus.isDescendant(of: toolsScroll), "A detailed failure scrolls instead of covering the inputs")
  for control in [start as NSView, end, navigation, playback, taskStatus] {
    control.scrollToVisible(control.bounds)
    let frame = toolsScroll.documentView!.convert(control.bounds, from: control)
    check(frame.intersects(toolsScroll.documentVisibleRect), "Every input and task detail is reachable by scrolling at height \(height)")
  }
}
}
taskStatus.stringValue = originalTaskStatus
layoutTools(height: 600)
toolsScroll.contentView.scroll(to: .zero)
toolsScroll.reflectScrolledClipView(toolsScroll.contentView)

// Capture the actual AppKit hierarchy in both appearances without changing test behavior.
if let captureDirectory = ProcessInfo.processInfo.environment["CHENGYING_CAPTURE_DIR"] {
  let directory = URL(fileURLWithPath: captureDirectory, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let language = Bundle.main.preferredLocalizations.first ?? "en"
  let sourceLabel = property("sourceLabel", as: NSTextField.self)
  let originalSource = sourceLabel.stringValue
  sourceLabel.stringValue = "Summer by the sea · 4K.mp4"
  func refreshSnapshotDisplay(_ view: NSView) {
    view.needsDisplay = true
    view.subviews.forEach(refreshSnapshotDisplay)
  }
  for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    panel.appearance = NSAppearance(named: appearance)
    for height in [350, 400, 600, 1200] {
      panel.setContentSize(NSSize(width: 320, height: height))
      controller.view.layoutSubtreeIfNeeded()
      controller.viewDidLayout()
      controller.view.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      controller.view.layoutSubtreeIfNeeded()
      for control in [modes, playback, frames, navigation] {
        let rect = controller.view.convert(control.bounds, from: control)
        check(rect.minX >= 0 && rect.maxX <= 320, "Captured segmented control fits \(name) sidebar")
      }
      guard let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) else {
        fatalError("Unable to allocate native control screenshot")
      }
      refreshSnapshotDisplay(controller.view)
      controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode native control screenshot")
      }
      try png.write(to: directory.appendingPathComponent("video-tools-\(language)-\(name)-\(height).png"))
      if height == 350 {
        action(preview)
        taskStatus.stringValue = syntheticFailure
        layoutTools(height: 350)
        taskStatus.scrollToVisible(taskStatus.bounds)
        refreshSnapshotDisplay(controller.view)
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to:
          directory.appendingPathComponent("video-tools-\(language)-\(name)-active-failure-350.png"))
        action(preview)
        taskStatus.stringValue = originalTaskStatus
        layoutTools(height: 350)
        toolsScroll.contentView.scroll(to: .zero)
        toolsScroll.reflectScrolledClipView(toolsScroll.contentView)
      }
    }
    panel.setContentSize(NSSize(width: 320, height: 600))
    for (index, operation) in [(1, "frames"), (2, "rotate"), (3, "convert")] {
      modes.selectedSegment = index
      action(modes)
      controller.view.layoutSubtreeIfNeeded()
      controller.viewDidLayout()
      controller.view.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      controller.view.layoutSubtreeIfNeeded()
      guard let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) else {
        fatalError("Unable to allocate native operation screenshot")
      }
      refreshSnapshotDisplay(controller.view)
      controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode native operation screenshot")
      }
      try png.write(to: directory.appendingPathComponent("video-tools-\(language)-\(name)-\(operation).png"))
    }
    modes.selectedSegment = 0
    action(modes)
  }
  sourceLabel.stringValue = originalSource
  panel.appearance = nil
  panel.setContentSize(NSSize(width: 320, height: 600))
  controller.view.layoutSubtreeIfNeeded()
  controller.viewDidLayout()
}
let initialRunRect = controller.view.convert(run.bounds, from: run)
check(initialRunRect.width >= 240 && initialRunRect.minY >= 0 && initialRunRect.maxY <= 600,
      "Primary export action remains visible in a 320 by 600 sidebar")
for (name, field) in [("start", start), ("end", end)] {
  check(field.frame.width >= 130, "\(name) timestamp has room for microsecond precision at sidebar width")
}
for control in [modes, playback, frames, navigation] {
  let widths = (0..<control.segmentCount).map { control.width(forSegment: $0) }
  check(widths.allSatisfy { $0 > 0 } && abs(widths.reduce(0, +) - control.bounds.width) < 0.1,
        "Segment widths fit their control on the first narrow layout")
}
// Momentary controls expose a selected segment only during mouse tracking.
// Preserve a synthetic selection while invoking their actual target/action.
for control in [playback, frames, navigation] { control.trackingMode = .selectOne }

playback.selectedSegment = 2; action(playback)
check(near(player.mpv.getDouble("time"), 15), "Forward by five seconds")
playback.selectedSegment = 0; action(playback)
check(near(player.mpv.getDouble("time"), 10), "Backward by five seconds")
player.mpv.values["time"] = 2.0; action(playback)
check(near(player.mpv.getDouble("time"), 0), "Backward clamps to zero")
player.mpv.values["time"] = 118.0; playback.selectedSegment = 2; action(playback)
check(near(player.mpv.getDouble("time"), 119.999) && player.mpv.getFlag("pause"), "Forward clamps and pauses before file end")
playback.selectedSegment = 1; action(playback)
check(!player.mpv.getFlag("pause"), "Play resumes")
frames.selectedSegment = 0; action(frames)
check(player.lastStepBackwards == true && player.mpv.getFlag("pause"), "Previous frame pauses and steps")
frames.selectedSegment = 1; action(frames)
check(player.lastStepBackwards == false && player.mpv.getFlag("pause"), "Next frame pauses and steps")
speeds.selectItem(at: 1); action(speeds)
check(near(player.mpv.getDouble("speed"), 0.5), "Speed popup selects half speed")
action(faster); check(near(player.mpv.getDouble("speed"), 0.6), "Faster adds one tenth")
action(slower); check(near(player.mpv.getDouble("speed"), 0.5), "Slower picks previous speed")
player.mpv.values["speed"] = 1.1
action(faster); check(near(player.mpv.getDouble("speed"), 1.2), "Faster handles arbitrary current speed")
player.mpv.values["time"] = 59.9999996; action(setStart)
check(start.stringValue == "01:00.000000", "Timestamp rounds across minute boundary")
player.mpv.values["time"] = 12.123456; action(setStart)
check(start.stringValue == "00:12.123456", "Start marker preserves microsecond precision")
player.mpv.values["time"] = 18.987654; action(setEnd)
check(end.stringValue == "00:18.987654", "End marker preserves microsecond precision")
navigation.selectedSegment = 0; action(navigation)
check(near(player.mpv.getDouble("time"), 12.123456) && player.mpv.getFlag("pause"), "Navigate to start pauses exactly")
navigation.selectedSegment = 1; action(navigation)
check(near(player.mpv.getDouble("time"), 18.987654), "Navigate to end seeks exactly")
action(preview)
check(near(player.mpv.getDouble("a"), 12.123456) && near(player.mpv.getDouble("b"), 18.987654) && player.mpv.getString("count") == "inf", "Range preview loops selected interval")
check(!player.mpv.getFlag("pause"), "Range preview starts playback")
action(preview)
check(player.mpv.getString("count") == "0" && player.mpv.getFlag("pause") && near(player.mpv.getDouble("time"), 18.987654), "Stopping preview restores original position and pause")
modes.selectedSegment = 1; action(modes)
check(end.stringValue == "00:17.123456", "Frame mode defaults end to start plus five seconds")
check(!frameFormatGroup.isHidden && frameFormat.isEnabled,
      "Frame extraction exposes its format selector")
player.mpv.values["time"] = 118.25; action(setStart)
check(end.stringValue == "02:00.000000", "Frame range end clamps to duration")
RunLoop.main.run(until: Date().addingTimeInterval(0.45))
check(player.videoToolsLoopRange == VideoToolsLoopRange(start: 118.25, end: 120) && !player.mpv.getFlag("pause"),
      "The clamped default frame range starts automatic preview after marking")
controller.stopPreview()
player.mpv.values["time"] = 10.0; action(setStart)
action(run)
check(VideoToolsTaskManager.shared.request?.operation == .frames && VideoToolsTaskManager.shared.request?.start == 10 && VideoToolsTaskManager.shared.request?.end == 15, "Run sends exact frame extraction range")
check(VideoToolsTaskManager.shared.request?.frameFormat == "jpg",
      "A default extraction sends JPG to the actual request model")
let jpgRequestJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(VideoToolsTaskManager.shared.request!)) as! [String: Any]
check(jpgRequestJSON["frame_format"] as? String == "jpg", "Frame format encodes with the helper protocol key")
frameFormat.selectItem(at: 1); action(frameFormat)
action(run)
check(VideoToolsTaskManager.shared.request?.frameFormat == "png" && Preference.string(for: .frameExtractionFormat) == "png",
      "An explicit PNG selection is dispatched and remembered")
check(frameFormatHint.stringValue == NSLocalizedString("videotools.frames.hint.png", comment: ""),
      "The lossless selection explains PNG and EXR behavior")
do {
  let remembered = VideoToolsViewController(player: PlayerCore(), mainWindow: MainWindowController())
  _ = remembered.view
  let popup = Mirror(reflecting: remembered).children.first(where: { $0.label == "frameFormatPopup" })!.value as! NSPopUpButton
  check(popup.indexOfSelectedItem == 1, "A reopened panel keeps the saved PNG choice")
}
Preference.set("unsupported", for: .frameExtractionFormat)
do {
  let invalidPreference = VideoToolsViewController(player: PlayerCore(), mainWindow: MainWindowController())
  _ = invalidPreference.view
  let popup = Mirror(reflecting: invalidPreference).children.first(where: { $0.label == "frameFormatPopup" })!.value as! NSPopUpButton
  check(popup.indexOfSelectedItem == 0 && Preference.string(for: .frameExtractionFormat) == "unsupported",
        "An unsupported saved format falls back safely without rewriting the stored choice")
}
frameFormat.selectItem(at: 0); action(frameFormat)
start.stringValue = "11.123456"; controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: start))
check(end.stringValue == "00:16.123456", "Typing start updates frame end")
RunLoop.main.run(until: Date().addingTimeInterval(0.45))
check(player.mpv.getString("count") == "inf" && near(player.mpv.getDouble("a"), 11.123456), "Typing valid range automatically previews")
end.stringValue = "bad"; controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: end))
check(player.mpv.getString("count") == "0", "Invalid input stops previous range preview")
check(previewStatus.stringValue == NSLocalizedString("videotools.preview.invalid", comment: ""),
      "Invalid input explains why automatic preview has stopped")
let invalidTimes = ["nan", "inf", "-1", "1:60", "1:60:00", "1.1234567", "1e3", "359999999999999999999999999999999999", "1::2"]
for value in invalidTimes {
  VideoToolsTaskManager.shared.request = nil
  start.stringValue = value; end.stringValue = "20"; action(run)
  check(VideoToolsTaskManager.shared.request == nil, "Reject invalid timestamp \(value)")
}
modes.selectedSegment = 0; action(modes)
start.stringValue = "10"; end.stringValue = "20"
player.pause()
controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: end))
playback.selectedSegment = 1; action(playback)
RunLoop.main.run(until: Date().addingTimeInterval(0.45))
check(player.mpv.getString("count") == "0", "Play action cancels pending automatic preview")
action(preview)
player.mpv.values["time"] = 14.0
playback.selectedSegment = 2; action(playback)
check(near(player.mpv.getDouble("time"), 19) && player.mpv.getString("count") == "0", "Manual seek leaves the temporary preview without restoring its old position")
playback.selectedSegment = 2; action(playback)
check(near(player.mpv.getDouble("time"), 24) && player.mpv.getString("count") == "0", "Forward navigation can select a later endpoint outside the old preview")
action(preview)
player.mpv.values["time"] = 16.123456
action(setStart)
check(start.stringValue == "00:16.123456" && near(player.mpv.getDouble("time"), 16.123456) && player.mpv.getFlag("pause") && player.mpv.getString("count") == "0", "Marking during preview immediately pauses at the selected frame before the new debounce")
RunLoop.main.run(until: Date().addingTimeInterval(0.45))
check(player.videoToolsLoopRange == VideoToolsLoopRange(start: 16.123456, end: 20) && !player.mpv.getFlag("pause"),
      "Marking during preview restarts the updated range automatically after the debounce")
controller.stopPreview()
let rotation = property("rotationControl", as: NSSegmentedControl.self)
let rotationPreview = property("rotationPreviewButton", as: NSButton.self)
modes.selectedSegment = 2; action(modes)
player.mpv.values["rotation"] = 180
rotation.selectedSegment = 0; action(rotationPreview)
check(player.mpv.getInt("rotation") == 90, "Rotation preview applies selected angle")
rotation.selectedSegment = 3; action(rotation)
check(player.mpv.getInt("rotation") == 0, "Full-turn preview maps to zero rotation")
action(rotationPreview)
check(player.mpv.getInt("rotation") == 180, "Rotation preview restores prior rotation")
modes.selectedSegment = 0; action(modes)
player.mpv.values["eof"] = true
check(player.videoToolsCurrentTime == 120, "EOF marker reads full duration")
player.mpv.values["eof"] = false
let captured = player.videoToolsCaptureSnapshot()!
player.videoToolsMediaGeneration += 1
player.mpv.values["time"] = 80.0
player.mpv.values["rotation"] = 270
player.videoToolsRestoreSnapshot(captured)
check(player.mpv.getInt("rotation") == 270 && player.mpv.getDouble("time") == 80, "Stale media snapshot cannot affect next file")
player.videoToolsRestorePreviewBeforeUnload(captured)
check(player.mpv.getInt("rotation") == captured.rotation && player.mpv.getDouble("time") == 80, "Unload restores preview options without seeking")
controller.setPlaybackControlsVisible(true)
let readsBefore = player.mpv.reads
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
check(player.mpv.reads > readsBefore, "Visible controls refresh on timer")
controller.setPlaybackControlsVisible(false)
let hiddenReadsBefore = player.mpv.reads
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
check(player.mpv.reads == hiddenReadsBefore, "Hidden controls stop timer")
print("Control frames at 320-point width:")
for (name, control) in [("playback", playback as NSView), ("frames", frames), ("speed", speeds), ("start", start), ("end", end), ("startButton", setStart), ("endButton", setEnd)] {
  let rect = controller.view.convert(control.bounds, from: control)
  print("\(name): \(rect)")
  check(rect.width > 0 && rect.minX >= 0 && rect.maxX <= 320, "\(name) fits sidebar width")
}

// Exercise the actual public keyboard entry points and their AppKit target/actions.
let loopStatus = property("loopStatusLabel", as: NSTextField.self)
let clearLoop = property("clearLoopButton", as: NSButton.self)
let status = property("statusLabel", as: NSTextField.self)
let cancel = property("cancelButton", as: NSButton.self)
let rotationStatus = property("shortcutRotationLabel", as: NSTextField.self)
let reveal = property("revealButton", as: NSButton.self)
func pumpTasks(until predicate: () -> Bool) {
  let deadline = Date().addingTimeInterval(2)
  while !predicate(), Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
  }
  check(predicate(), "Expected asynchronous UI task state was reached")
}
func localized(_ key: String) -> String { NSLocalizedString(key, comment: "Test UI localization") }

action(clearLoop)
modes.selectedSegment = 1; action(modes)
player.resume()
player.mpv.values["time"] = 0.0
check(controller.setLoopMarker(isEnd: false), "A reports success to the keyboard OSD router")
check(player.mpv.getString("a") == "0.0" && player.mpv.getString("count") == "0", "Public A marker accepts zero without starting a loop")
check(start.stringValue == "00:00.000000" && end.stringValue == "00:05.000000", "Public A marker updates frame range with the default five-second end")
check(!player.mpv.getFlag("pause"), "Public A marker does not pause playback")
check(loopStatus.stringValue == String(format: localized("videotools.loop.start"), "00:00.000"), "A marker status displays a localized pending endpoint")
check(!controller.setLoopMarker(isEnd: true), "Invalid B reports failure to the keyboard OSD router")
check(player.videoToolsLoopRange == nil && status.stringValue == localized("videotools.error.loop_end"), "Public B equal to A is rejected with the localized error")
player.mpv.values["time"] = 4.0
check(controller.setLoopMarker(isEnd: true), "Valid B reports success to the keyboard OSD router")
check(player.videoToolsLoopRange == VideoToolsLoopRange(start: 0, end: 4), "Public B starts the selected zero-based loop")
check(start.stringValue == "00:00.000000" && end.stringValue == "00:04.000000", "Public B writes both exact fields")
check(near(player.mpv.getDouble("time"), 0) && !player.mpv.getFlag("pause"), "Public B returns to A without changing the playback pause state")
check(loopStatus.stringValue == String(format: localized("videotools.loop.active"), "00:00.000", "00:04.000"), "Active keyboard loop displays the localized exact range")
check(clearLoop.isEnabled && preview.title == localized("videotools.preview_range"),
      "Clear A/B stays explicit while the separate preview action never silently clears it")
controller.setLoopMarker(isEnd: true)
check(player.videoToolsLoopRange == VideoToolsLoopRange(start: 0, end: 4), "An invalid replacement B preserves the existing valid loop")
player.mpv.values["time"] = -1.0
controller.setLoopMarker(isEnd: true)
check(player.videoToolsLoopRange == VideoToolsLoopRange(start: 0, end: 4), "B before A does not damage the active range")
player.mpv.values["time"] = 1.0
controller.setPlaybackControlsVisible(false)
controller.stopPreview()
check(player.videoToolsLoopRange == VideoToolsLoopRange(start: 0, end: 4), "Hiding the tools panel does not cancel a keyboard-owned loop")
action(preview)
check(preview.title == localized("videotools.stop_preview") && player.videoToolsLoopRange == VideoToolsLoopRange(start: 0, end: 4),
      "Preview temporarily owns the current range without clearing the keyboard loop")
start.stringValue = "10"; end.stringValue = "15"
controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: end))
check(previewStatus.stringValue == localized("videotools.preview.pending"), "Typing exposes the pending preview state")
RunLoop.main.run(until: Date().addingTimeInterval(0.45))
check(player.videoToolsLoopRange == VideoToolsLoopRange(start: 10, end: 15), "Editing updates the temporary preview range")
check(previewStatus.stringValue == String(format: localized("videotools.preview.active"), "00:10.000", "00:15.000"),
      "Preview status displays the actual current range and player destination")
action(preview)
check(player.videoToolsLoopRange == VideoToolsLoopRange(start: 0, end: 4) && near(player.mpv.getDouble("time"), 1),
      "Stopping edited preview restores the original keyboard loop and position")
action(preview)
controller.stopPreview()
check(player.videoToolsLoopRange == VideoToolsLoopRange(start: 0, end: 4),
      "Closing the panel restores the keyboard loop replaced by temporary preview")
action(preview)
let positionBeforePreviewUnload = player.mpv.getDouble("time")
var previewUnloadCompleted = false
player.mpv.hooks[0].block { previewUnloadCompleted = true }
pumpTasks { previewUnloadCompleted }
check(player.videoToolsLoopRange == VideoToolsLoopRange(start: 0, end: 4) && near(player.mpv.getDouble("time"), positionBeforePreviewUnload),
      "Unload restores the saved keyboard options without seeking the outgoing media")
player.videoToolsClearLoop()
player.videoToolsMediaGeneration += 1
controller.refreshCurrentMedia(force: true)
check(player.videoToolsLoopRange == nil && preview.title == localized("videotools.preview_range"),
      "Opening another media generation does not revive the old preview or keyboard loop")

// Keyboard markers supersede the panel's pending automatic preview timer.
modes.selectedSegment = 0; action(modes)
start.stringValue = "10"; end.stringValue = "15"
controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: end))
player.mpv.values["time"] = 30.0
controller.setLoopMarker(isEnd: false)
player.mpv.values["time"] = 35.0
controller.setLoopMarker(isEnd: true)
RunLoop.main.run(until: Date().addingTimeInterval(0.45))
check(player.videoToolsLoopRange == VideoToolsLoopRange(start: 30, end: 35), "An old automatic-preview timer cannot replace keyboard markers")
player.mpv.values["time"] = 29.0
controller.setLoopMarker(isEnd: true)
check(player.videoToolsLoopRange == VideoToolsLoopRange(start: 30, end: 35), "B strictly before a nonzero A preserves the active interval")
check(status.stringValue == localized("videotools.error.loop_end"), "Invalid replacement B surfaces the localized validation message")
action(clearLoop)
check(player.videoToolsLoopRange == nil && !clearLoop.isEnabled, "Dedicated clear button disables the loop and its markers")

let taskManager = VideoToolsTaskManager.shared
taskManager.simulatesTaskLifecycle = true
taskManager.requests.removeAll()
taskManager.request = nil
taskManager.snapshot = nil
player.mpv.values["rotation"] = 0
player.mpv.values["time"] = 30.0
controller.setLoopMarker(isEnd: false)
player.mpv.values["time"] = 35.0
controller.setLoopMarker(isEnd: true)
player.resume()
let rotationSource = player.info.currentURL!
controller.requestPermanentRotation(clockwiseQuarterTurns: -1)
check(player.mpv.getInt("rotation") == 270 && rotation.selectedSegment == 2, "Public left shortcut immediately previews a counterclockwise quarter turn")
check(modes.selectedSegment == 2 && !rotationStatus.isHidden, "Public rotation shortcut exposes the native rotation mode and status")
check(rotationStatus.stringValue.contains(localized("videotools.rotation.direction.left")), "Left rotation status displays the localized direction")
check(rotationStatus.stringValue.contains(localized("videotools.rotation.shortcut_pending")), "Debounced export is visibly pending")
check(!run.isEnabled && !cancel.isHidden && cancel.isEnabled, "Pending shortcut export disables manual run and enables cancellation")
check(player.videoToolsLoopRange == VideoToolsLoopRange(start: 30, end: 35) && !player.mpv.getFlag("pause"), "Permanent rotation does not interrupt a keyboard loop or pause playback")
controller.requestPermanentRotation(clockwiseQuarterTurns: -1)
check(player.mpv.getInt("rotation") == 180 && rotation.selectedSegment == 1, "Two public left presses accumulate to a half turn")
controller.requestPermanentRotation(clockwiseQuarterTurns: 1)
check(player.mpv.getInt("rotation") == 270, "A following right press reduces the cumulative left rotation")
action(cancel)
check(player.mpv.getInt("rotation") == 0 && cancel.isHidden && run.isEnabled, "Cancelling during debounce restores the last completed orientation and unlocks the panel")
check(status.stringValue == localized("videotools.status.cancelled"), "Debounce cancellation is shown as cancelled rather than ready")
RunLoop.main.run(until: Date().addingTimeInterval(0.35))
check(taskManager.requests.isEmpty, "Cancelling the pending UI request prevents an export")

let writesBeforeRotationExport = player.mpv.intWrites["rotation", default: []].count
controller.requestPermanentRotation(clockwiseQuarterTurns: 1)
check(player.mpv.getInt("rotation") == 90 && rotationStatus.stringValue.contains(localized("videotools.rotation.direction.right")), "Public right shortcut starts at the reset orientation and displays its direction")
pumpTasks { taskManager.requests.count == 1 }
check(taskManager.request?.operation == .rotate && taskManager.request?.degrees == 90 && taskManager.request?.inputPath == rotationSource.path, "The UI exports its first angle from the original file")
for progress in [0.0, 1.0, 25.0, 50.0] {
  taskManager.reportProgress(progress)
}
check(player.mpv.intWrites["rotation", default: []].count == writesBeforeRotationExport + 1,
      "Starting and progress notifications do not rewrite the current display rotation")
check(property("progressIndicator", as: NSProgressIndicator.self).doubleValue == 50,
      "Rotation progress still updates the actual native panel")
let writesBeforeRapidRotation = player.mpv.intWrites["rotation", default: []].count
controller.requestPermanentRotation(clockwiseQuarterTurns: 1)
check(player.mpv.getInt("rotation") == 180 && rotationStatus.stringValue.contains(localized("videotools.rotation.shortcut_queued")), "An in-flight shortcut updates preview and reports the queued cumulative target")
controller.requestPermanentRotation(clockwiseQuarterTurns: -1)
controller.requestPermanentRotation(clockwiseQuarterTurns: 1)
check(Array(player.mpv.intWrites["rotation", default: []].dropFirst(writesBeforeRapidRotation)) == [180, 90, 180],
      "Rapid right-left-right shortcuts apply every distinct cumulative angle immediately")
action(run)
check(taskManager.requests.count == 1 && status.stringValue == localized("videotools.error.busy"), "Manual run cannot take over a pending cumulative rotation")
let firstRotationOutput = URL(fileURLWithPath: "/tmp/chengying-rotation-first.mkv")
taskManager.finishTask(.completed, outputURL: firstRotationOutput)
pumpTasks { taskManager.requests.count == 2 }
check(taskManager.request?.degrees == 180 && taskManager.request?.inputPath == rotationSource.path, "The queued UI angle is rendered from the original, not the previous output")
let secondRotationOutput = URL(fileURLWithPath: "/tmp/chengying-rotation-second.mkv")
taskManager.finishTask(.completed, outputURL: secondRotationOutput)
check(player.mpv.intWrites["rotation", default: []].count == writesBeforeRapidRotation + 3,
      "Completion and queued export startup do not rewrite the unchanged display rotation")
check(player.mpv.getInt("rotation") == 180 && !reveal.isHidden && cancel.isHidden, "Completed rotation remains visible and offers its output without a cancel action")
check(rotationStatus.stringValue.contains(localized("videotools.rotation.shortcut_saved")), "Successful rotation status explains where the output was saved")
controller.setPlaybackControlsVisible(false)
controller.stopPreview()
check(player.mpv.getInt("rotation") == 180 && player.videoToolsLoopRange == VideoToolsLoopRange(start: 30, end: 35), "Hiding the panel preserves both permanent-rotation preview and keyboard loop")

controller.requestPermanentRotation(clockwiseQuarterTurns: -1)
pumpTasks { taskManager.requests.count == 3 }
controller.requestPermanentRotation(clockwiseQuarterTurns: -1)
let cancelledTaskID = taskManager.snapshot!.id
action(cancel)
check(taskManager.cancellations.last == cancelledTaskID && taskManager.snapshot?.phase == .cancelling, "The panel cancels its own active shortcut task by identity")
check(player.mpv.getInt("rotation") == 180 && !cancel.isEnabled, "Cancellation rolls preview back to the last completed angle and disables repeated cancellation")
taskManager.finishTask(.cancelled)
RunLoop.main.run(until: Date().addingTimeInterval(0.35))
check(taskManager.requests.count == 3 && cancel.isHidden && run.isEnabled, "Cancelled in-flight rotation discards every queued shortcut")

// A different window's helper job must not be taken over or cancelled by this UI.
try taskManager.start(operation: .frames, inputURL: rotationSource, start: 0, end: 1, degrees: nil, outputDirectory: nil)
check(!frameFormat.isEnabled, "An active helper task locks frame format changes")
let foreignTaskID = taskManager.snapshot!.id
let cancellationsBeforeBusy = taskManager.cancellations.count
controller.requestPermanentRotation(clockwiseQuarterTurns: 1)
check(player.mpv.getInt("rotation") == 180 && status.stringValue == localized("videotools.error.busy"), "A foreign busy task rejects rotation without changing the displayed angle")
action(cancel)
check(taskManager.snapshot?.id == foreignTaskID && taskManager.cancellations.count == cancellationsBeforeBusy, "The panel cannot cancel a helper task owned by another window")
taskManager.finishTask(.completed)
check(frameFormat.isEnabled, "Completing a helper task unlocks the frame format selector")

controller.requestPermanentRotation(clockwiseQuarterTurns: 1)
pumpTasks { taskManager.requests.count == 5 }
controller.requestPermanentRotation(clockwiseQuarterTurns: 1)
var unloadContinued = false
for hook in player.mpv.hooks { hook.block { unloadContinued = true } }
pumpTasks { unloadContinued }
check(player.mpv.getInt("rotation") == 0, "The real unload hook restores the display orientation from before shortcut rotation")
check(taskManager.snapshot?.phase == .cancelling, "The real unload hook cancels the current shortcut export")
taskManager.finishTask(.cancelled)
RunLoop.main.run(until: Date().addingTimeInterval(0.35))
check(taskManager.requests.count == 5, "Unloading media discards queued exports instead of producing stale outputs")
player.videoToolsMediaGeneration += 1
controller.refreshCurrentMedia(force: true)
controller.requestPermanentRotation(clockwiseQuarterTurns: -1)
check(player.mpv.getInt("rotation") == 270, "Reloading the same path begins a fresh cumulative rotation generation")
action(cancel)

// Validate the production bridge independently of the panel's normalized inputs.
let rotationProbe = PlayerCore()
for degrees in [90, 180, 270, 360, 0] {
  rotationProbe.videoToolsPreviewRotation(degrees)
}
check(rotationProbe.mpv.intWrites["rotation"] == [90, 180, 270, 0],
      "Every supported quarter turn is applied and equivalent full turns are not repeated")
for degrees in [Int.min, -90, -1, 45, 361, 450, Int.max] {
  rotationProbe.videoToolsPreviewRotation(degrees)
}
check(rotationProbe.mpv.intWrites["rotation"] == [90, 180, 270, 0],
      "Unsupported preview angles cannot reach the player rotation property")
rotationProbe.mpv.values["rotation"] = 270
rotationProbe.videoToolsPreviewRotation(0)
check(rotationProbe.mpv.intWrites["rotation"] == [90, 180, 270, 0, 0],
      "Preview compares the actual player angle after another entry point changes it")
rotationProbe.info.state = .idle
rotationProbe.videoToolsPreviewRotation(90)
check(rotationProbe.mpv.intWrites["rotation"] == [90, 180, 270, 0, 0],
      "Unloaded media cannot receive preview rotation writes")

// Conversion is a whole-file operation, even when a keyboard loop remains active.
let conversionFormat = property("conversionFormatPopup", as: NSPopUpButton.self)
let conversionMode = property("conversionModePopup", as: NSPopUpButton.self)
let conversionHint = property("conversionHintLabel", as: NSTextField.self)
let conversionGroup = property("conversionGroup", as: NSStackView.self)
let timeGroup = property("timeGroup", as: NSStackView.self)
let rotationGroup = property("rotationGroup", as: NSStackView.self)
let playbackGroup = property("playbackGroup", as: NSView.self)
let outputGroup = property("outputGroup", as: NSStackView.self)
check(modes.segmentCount == 4, "Conversion is the fourth native tool mode")
modes.selectedSegment = 3; action(modes)
check(!conversionGroup.isHidden && timeGroup.isHidden && rotationGroup.isHidden && playbackGroup.isHidden && !outputGroup.isHidden,
      "Whole-file conversion hides range, rotation and playback settings while retaining the output folder")
check(run.title == localized("videotools.run_convert"), "Conversion action explicitly says it processes the entire video")
check(conversionFormat.itemTitles == ["MP4", "MKV", "MOV"] && conversionFormat.indexOfSelectedItem == 0,
      "Only supported containers are offered and MP4 is the default")
check(conversionMode.numberOfItems == 3 && conversionMode.indexOfSelectedItem == 0,
      "Lossless remux is the default among the three conversion modes")
check(conversionHint.stringValue == localized("videotools.conversion.hint.copy"),
      "The default conversion hint explains lossless stream copying")
player.mpv.values["time"] = 10.0
controller.setLoopMarker(isEnd: false)
player.mpv.values["time"] = 15.0
controller.setLoopMarker(isEnd: true)
player.mpv.values["speed"] = 2.0
start.stringValue = "invalid range"
end.stringValue = "not a time"
action(run)
check(taskManager.request?.operation == .convert && taskManager.request?.targetFormat == "mp4" && taskManager.request?.conversionMode == "copy",
      "The UI dispatches MP4 lossless conversion without requiring a valid A/B selection")
check(taskManager.request?.start == nil && taskManager.request?.end == nil && taskManager.request?.degrees == nil,
      "Conversion requests never carry clip markers or preview rotation")
check(taskManager.request?.outputDirectory == player.info.currentURL?.deletingLastPathComponent().path,
      "Conversion defaults to the original file's parent directory")
check(player.videoToolsLoopRange == VideoToolsLoopRange(start: 10, end: 15) && player.mpv.getDouble("speed") == 2,
      "Starting conversion preserves the player's independent loop and speed")
check(!run.isEnabled && !cancel.isHidden && !conversionFormat.isEnabled && !conversionMode.isEnabled,
      "Active conversion exposes cancellation and locks conversion options")
check(status.stringValue.contains(VideoToolsOperation.convert.localizedName) && !status.stringValue.contains(localized("videotools.status.cancelled")),
      "A previous cancelled shortcut rotation cannot hide the new conversion task status")
let conversionRequestData = try JSONEncoder().encode(taskManager.request!)
let conversionRequestJSON = try JSONSerialization.jsonObject(with: conversionRequestData) as! [String: Any]
check(conversionRequestJSON["operation"] as? String == "convert" && conversionRequestJSON["target_format"] as? String == "mp4" && conversionRequestJSON["conversion_mode"] as? String == "copy",
      "Conversion request fields use the helper's snake-case protocol names")
check(conversionRequestJSON["start"] == nil && conversionRequestJSON["end"] == nil && conversionRequestJSON["degrees"] == nil && conversionRequestJSON["frame_format"] == nil,
      "Whole-file conversion omits unrelated JSON fields")
let cancelledConversionID = taskManager.snapshot!.id
action(cancel)
check(taskManager.cancellations.last == cancelledConversionID && taskManager.snapshot?.phase == .cancelling,
      "The conversion panel cancels its own helper task")
taskManager.finishTask(.cancelled)
check(run.isEnabled && conversionFormat.isEnabled && conversionMode.isEnabled,
      "Cancelled conversion restores the settings and run action")
for (formatIndex, formatName) in [(1, "mkv"), (2, "mov")] {
  conversionFormat.selectItem(at: formatIndex)
  for (modeIndex, modeName) in [(1, "h264"), (2, "hevc")] {
    conversionMode.selectItem(at: modeIndex); action(conversionMode)
    check(conversionHint.stringValue == localized("videotools.conversion.hint.\(modeName)"),
          "\(modeName) selection explains quality and encoding cost")
    action(run)
    check(taskManager.request?.targetFormat == formatName && taskManager.request?.conversionMode == modeName,
          "\(formatName) / \(modeName) settings reach the helper request")
    taskManager.finishTask(.completed, outputURL: URL(fileURLWithPath: "/tmp/converted output.\(formatName)"))
    check(!reveal.isHidden && cancel.isHidden && run.isEnabled,
          "Completed \(formatName) / \(modeName) conversion exposes its output and unlocks the panel")
  }
}
let cancelRequestData = try JSONEncoder().encode(VideoToolsRequest.cancel(id: "cancel", targetID: "convert"))
let cancelRequestJSON = try JSONSerialization.jsonObject(with: cancelRequestData) as! [String: Any]
check(cancelRequestJSON["target_format"] == nil && cancelRequestJSON["conversion_mode"] == nil && cancelRequestJSON["frame_format"] == nil,
      "Cancel requests do not leak conversion settings")
let shutdownRequestData = try JSONEncoder().encode(VideoToolsRequest.shutdown(id: "shutdown"))
let shutdownRequestJSON = try JSONSerialization.jsonObject(with: shutdownRequestData) as! [String: Any]
check(shutdownRequestJSON["target_format"] == nil && shutdownRequestJSON["conversion_mode"] == nil && shutdownRequestJSON["frame_format"] == nil,
      "Shutdown requests do not leak conversion settings")
modes.selectedSegment = 0; action(modes)
check(conversionGroup.isHidden && !timeGroup.isHidden && !playbackGroup.isHidden,
      "Switching back to clip restores the range and playback controls")

// Exercise the task notification path at the user's short sidebar height.
start.stringValue = "10"; end.stringValue = "15"
layoutTools(height: 350)
action(run)
let cancelFrame = controller.view.convert(cancel.bounds, from: cancel)
check(!cancel.isHidden && cancelFrame.minY >= 0 && cancelFrame.maxY <= 350,
      "The active export cancel action stays reachable in a short sidebar")
taskManager.snapshot?.message = syntheticFailure
taskManager.finishTask(.failed)
layoutTools(height: 350)
let errorFrame = toolsScroll.documentView!.convert(status.bounds, from: status)
check(errorFrame.intersects(toolsScroll.documentVisibleRect), "A failed owned task reveals its complete scrollable diagnostic")
for control in [preview as NSView, previewStatus, run] {
  let frame = controller.view.convert(control.bounds, from: control)
  check(frame.minY >= 0 && frame.maxY <= 350 && frame.height > 0,
        "Task failure cannot displace the preview and confirmation actions")
}
layoutTools(height: 600)

runVideoToolsShortcutTests()
runVideoToolsLoopTests()
check(VideoToolsPlaybackCommand.parse(["seek", "5"]) == .seek(5, .relative), "Parse relative seek")
check(VideoToolsPlaybackCommand.parse(["no-osd", "seek", "99", "absolute-percent+exact"]) == .seek(99, .absolutePercent), "Parse prefixed percent seek")
check(VideoToolsPlaybackCommand.parse(["seek", "-3", "relative-percent"]) == .seek(-3, .relativePercent), "Parse relative percent seek")
check(VideoToolsPlaybackCommand.parse(["frame-back-step"]) == .frame(backwards: true), "Parse backward frame command")
check(VideoToolsPlaybackCommand.parse(["multiply", "speed", "1/1.1"]) == .speed(1/1.1, .multiply), "Parse fractional speed multiplier")
check(VideoToolsPlaybackCommand.parse(["seek", "nan"]) == nil, "Reject invalid seek amount")
check(VideoToolsPlaybackCommand.parse(["multiply", "speed", "1/0"]) == nil, "Reject invalid speed multiplier")
check(VideoToolsPlaybackCommand.parse(["seek", "5;", "quit"]) == nil, "Do not silently truncate compound bindings")
print("SUCCESS: \(passes) checks passed")
