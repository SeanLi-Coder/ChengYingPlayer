import Cocoa
setbuf(stdout, nil)

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
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
let navigation = property("rangeNavigationControl", as: NSSegmentedControl.self)
let modes = property("modeControl", as: NSSegmentedControl.self)
let run = property("runButton", as: NSButton.self)
let faster = property("fasterButton", as: NSButton.self)
let slower = property("slowerButton", as: NSButton.self)
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
action(faster); check(near(player.mpv.getDouble("speed"), 0.75), "Faster picks next speed")
action(slower); check(near(player.mpv.getDouble("speed"), 0.5), "Slower picks previous speed")
player.mpv.values["speed"] = 1.1
action(faster); check(near(player.mpv.getDouble("speed"), 1.25), "Faster handles arbitrary current speed")
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
player.mpv.values["time"] = 118.25; action(setStart)
check(end.stringValue == "02:00.000000", "Frame range end clamps to duration")
player.mpv.values["time"] = 10.0; action(setStart)
action(run)
check(VideoToolsTaskManager.shared.request?.operation == .frames && VideoToolsTaskManager.shared.request?.start == 10 && VideoToolsTaskManager.shared.request?.end == 15, "Run sends exact frame extraction range")
start.stringValue = "11.123456"; controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: start))
check(end.stringValue == "00:16.123456", "Typing start updates frame end")
RunLoop.main.run(until: Date().addingTimeInterval(0.45))
check(player.mpv.getString("count") == "inf" && near(player.mpv.getDouble("a"), 11.123456), "Typing valid range automatically previews")
end.stringValue = "bad"; controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: end))
check(player.mpv.getString("count") == "0", "Invalid input stops previous range preview")
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
check(near(player.mpv.getDouble("time"), 19) && player.mpv.getString("count") == "0", "Manual seek leaves preview without restoring old position")
action(preview)
player.mpv.values["time"] = 16.123456
action(setStart)
check(start.stringValue == "00:16.123456" && near(player.mpv.getDouble("time"), 16.123456) && player.mpv.getFlag("pause") && player.mpv.getString("count") == "0", "Marking during preview preserves selected frame and stops loop")
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
print("SUCCESS: \(passes) checks passed")
