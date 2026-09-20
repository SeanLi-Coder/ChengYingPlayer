import Cocoa
import Darwin

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  checks += 1
  if !condition() { fputs("Slideshow UI check failed: \(message)\n", stderr); exit(1) }
}
func pump(_ duration: TimeInterval = 0.02) {
  let end = Date().addingTimeInterval(duration)
  while Date() < end {
    while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
      NSApp.sendEvent(event)
    }
    NSApp.updateWindows()
    RunLoop.main.run(until: Date().addingTimeInterval(0.002))
  }
}
func waitFor(_ message: String, timeout: TimeInterval = 6, _ condition: () -> Bool) {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition() && Date() < deadline { pump() }
  expect(condition(), message)
}
func send(_ control: NSControl) {
  guard let action = control.action else { expect(false, "Interactive control has an action"); return }
  NSApp.sendAction(action, to: control.target, from: control)
}
func textContent(_ view: NSView) -> String {
  let own = (view as? NSTextField)?.stringValue ?? ""
  return ([own] + view.subviews.map(textContent)).joined(separator: "\n")
}
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
func loaded(_ viewer: ImageViewerWindowController, _ url: URL) -> Bool {
  viewer.selectedURL?.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() && viewer.canvas.image != nil
}
func sameURL(_ left: URL?, _ right: URL?) -> Bool {
  left?.standardizedFileURL.resolvingSymlinksInPath() == right?.standardizedFileURL.resolvingSymlinksInPath()
}
func visible(_ control: NSView) -> Bool {
  !control.isHiddenOrHasHiddenAncestor && control.visibleRect.width > 10 && control.visibleRect.height > 8
}
func capture(_ viewer: ImageViewerWindowController, name: String) throws {
  guard let directory = ProcessInfo.processInfo.environment["IMAGE_SLIDESHOW_SCREENSHOT_DIR"],
        let content = viewer.window?.contentView,
        let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
  let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name + ".png")
  content.cacheDisplay(in: content.bounds, to: bitmap)
  if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: url) }
  print("Slideshow screenshot: \(url.path)")
  if let window = viewer.window {
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    let windowURL = url.deletingPathExtension().appendingPathExtension("window.png")
    capture.arguments = ["-x", "-l", String(window.windowNumber), "-o", windowURL.path]
    try capture.run()
    capture.waitUntilExit()
    if capture.terminationStatus == 0 { print("Slideshow window screenshot: \(windowURL.path)") }
  }
}
func nextImage(_ viewer: ImageViewerWindowController) { send(viewer.nextButton) }
func previousImage(_ viewer: ImageViewerWindowController) { send(viewer.previousButton) }
func dismissSheet(_ viewer: ImageViewerWindowController) {
  if let sheet = viewer.window?.attachedSheet {
    viewer.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    sheet.orderOut(nil)
    pump()
  }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.finishLaunching()
let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengying-slideshow-ui-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let suiteName = "io.chengying.tests.slideshow.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defaults.removePersistentDomain(forName: suiteName)
defer {
  defaults.removePersistentDomain(forName: suiteName)
  try? FileManager.default.removeItem(at: root)
}
func fixture(_ name: String, directory: String = "folder", bytes: Int = 17) throws -> URL {
  let directoryURL = root.appendingPathComponent(directory)
  try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
  let url = directoryURL.appendingPathComponent(name)
  try Data(repeating: 0, count: bytes).write(to: url)
  return url
}
let first = try fixture("2.png", bytes: 2048)
let second = try fixture("10.png", bytes: 4096)
let third = try fixture("30.png", bytes: 1024)
let taggedDate = Date(timeIntervalSince1970: 1_704_153_600)
try FileManager.default.setAttributes([.modificationDate: taggedDate], ofItemAtPath: first.path)
let storedTags = try PropertyListSerialization.data(fromPropertyList: ["ReviewRed\n6", "ReviewGreen\n2"], format: .binary, options: 0)
let tagResult = first.path.withCString { path in
  storedTags.withUnsafeBytes { data in
    setxattr(path, "com.apple.metadata:_kMDItemUserTags", data.baseAddress, data.count, 0, 0)
  }
}
expect(tagResult == 0, "Real Finder tag fixture is stored")
let viewer = ImageViewerWindowController(urls: [first], defaults: defaults)
expect(!viewer.slideshowButton.isEnabled, "Slideshow waits until initial directory enumeration finishes")
viewer.showWindow(nil)
viewer.window?.makeKeyAndOrderFront(nil)
NSApp.activate(ignoringOtherApps: true)
waitFor("Single image discovers all sibling images") { loaded(viewer, first) && viewer.files.count == 3 && viewer.slideshowButton.isEnabled }
expect(viewer.files.map(\.name) == ["2.png", "10.png", "30.png"], "Folder initially uses natural filename order")
expect(viewer.folderBrowser.tableView.numberOfRows == 3 && visible(viewer.folderBrowser.tableView),
       "Shared folder image browser is visible without opening another panel")
viewer.sidebarPicker.selectedSegment = 1
send(viewer.sidebarPicker)
pump()
expect(visible(viewer.tableView), "The current image sequence remains available in its list tab")
expect(viewer.tableView.selectedRow == 0 && viewer.selectedURL == first, "Directory enumeration keeps the opened image selected")
expect(viewer.folderLabel.stringValue.contains("folder"), "Folder heading identifies the current folder")
expect(viewer.slideshowInterval == 5, "Slideshow defaults to five seconds")
expect(viewer.loopSlideshowButton.state == .on, "Slideshow loops by default")
let row = viewer.tableView(viewer.tableView, viewFor: viewer.tableView.tableColumns[0], row: 0)!
let rowText = textContent(row)
expect(rowText.contains("ReviewRed") && rowText.contains("ReviewGreen"), "Folder row shows all Finder tag names")
expect(rowText.contains(ByteCountFormatter.string(fromByteCount: 2048, countStyle: .file)), "Tagged image still shows its file size")
let metadataFormatter = DateFormatter()
metadataFormatter.dateFormat = "yyyy-MM-dd HH:mm"
expect(rowText.contains(metadataFormatter.string(from: taggedDate)), "Tagged image also shows its actual modification date")
let rowFields = descendants(row).compactMap { $0 as? NSTextField }
var tagColors: [String: NSColor] = [:]
for field in rowFields {
  let value = field.attributedStringValue
  value.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: value.length)) { color, range, _ in
    guard let color = color as? NSColor, (value.string as NSString).substring(with: range).contains("●") else { return }
    tagColors[color.description] = color
  }
}
expect(tagColors.values.contains(NSColor.systemRed), "Red Finder label is rendered with its actual color")
expect(tagColors.values.contains(NSColor.systemGreen), "Green Finder label is rendered with its actual color")
viewer.sortPicker.selectItem(at: 2)
send(viewer.sortPicker)
expect(viewer.files.first?.name == "2.png" && viewer.selectedURL == first, "Modification-date sorting uses the actual timestamp without switching images")
viewer.sortPicker.selectItem(at: 3)
send(viewer.sortPicker)
let selectedAfterDateSort = viewer.tableView.selectedRow
let creationRow = viewer.tableView(viewer.tableView, viewFor: viewer.tableView.tableColumns[0], row: selectedAfterDateSort)!
let creationText = textContent(creationRow)
expect(creationText.contains("创建") && creationText.contains("ReviewRed"), "Creation-date sorting displays creation time alongside Finder tags")
if let creationDate = viewer.files[selectedAfterDateSort].creationDate {
  expect(creationText.contains(metadataFormatter.string(from: creationDate)), "Creation-date row shows the actual filesystem value")
} else {
  expect(creationText.contains("未知"), "Unavailable creation dates are identified honestly")
}
viewer.sortPicker.selectItem(at: 0)
send(viewer.sortPicker)
expect(viewer.files.map(\.name) == ["2.png", "10.png", "30.png"] && viewer.selectedURL == first,
       "Returning to name sorting restores natural order and preserves selection")

viewer.window?.setContentSize(NSSize(width: 1120, height: 760))
pump()
try capture(viewer, name: "slideshow-default")
viewer.window?.setContentSize(NSSize(width: 880, height: 620))
pump()
try capture(viewer, name: "slideshow-minimum")
for (name, control) in [("Folder list", viewer.tableView as NSView),
                        ("Slideshow toggle", viewer.slideshowButton),
                        ("Interval field", viewer.intervalField),
                        ("Interval slider", viewer.intervalSlider),
                        ("Interval stepper", viewer.intervalStepper),
                        ("Loop switch", viewer.loopSlideshowButton)] {
  expect(visible(control), "\(name) remains visible at the minimum window size")
}
expect(viewer.canvas.bounds.width > 300 && viewer.canvas.bounds.height > 180, "Slideshow controls leave a usable image canvas")

viewer.setSlideshowInterval(.nan)
viewer.setSlideshowInterval(.infinity)
viewer.setSlideshowInterval(0)
viewer.setSlideshowInterval(-1)
expect(viewer.slideshowInterval == 5, "Nonfinite and nonpositive interval values are ignored")
viewer.setSlideshowInterval(0.01)
expect(viewer.slideshowInterval == 0.5, "Positive interval values respect the lower bound")
viewer.setSlideshowInterval(500)
expect(viewer.slideshowInterval == 120, "Interval values respect the upper bound")
viewer.intervalField.stringValue = "0.5"
send(viewer.intervalField)
expect(viewer.slideshowInterval == 0.5, "Direct interval entry changes the actual slideshow timing")
viewer.intervalField.stringValue = "not-a-duration"
send(viewer.intervalField)
expect(viewer.slideshowInterval == 0.5 && viewer.intervalField.stringValue == "0.5", "Invalid text restores the last valid interval")
viewer.intervalField.stringValue = " 0,5 "
send(viewer.intervalField)
expect(viewer.slideshowInterval == 0.5, "Decimal comma and surrounding whitespace are accepted")
viewer.intervalStepper.doubleValue = 1
send(viewer.intervalStepper)
expect(viewer.slideshowInterval == 1, "Stepper changes the actual interval")
viewer.intervalSlider.doubleValue = viewer.intervalSlider.maxValue
send(viewer.intervalSlider)
expect(abs(viewer.slideshowInterval - 120) < 0.001, "Slider reaches the maximum interval")
viewer.intervalSlider.doubleValue = viewer.intervalSlider.minValue
send(viewer.intervalSlider)
expect(abs(viewer.slideshowInterval - 0.5) < 0.001, "Slider reaches the minimum interval")

send(viewer.slideshowButton)
expect(viewer.isSlideshowRunning, "Slideshow starts from the visible image")
pump(0.25)
expect(viewer.selectedURL == first, "First slide remains visible for its requested interval")
waitFor("Slideshow advances in current sort order") { loaded(viewer, second) }
send(viewer.slideshowButton)
expect(!viewer.isSlideshowRunning, "Slideshow button pauses playback")
pump(0.7)
expect(sameURL(viewer.selectedURL, second), "Paused slideshow does not advance")

viewer.setSlideshowInterval(1)
send(viewer.slideshowButton)
pump(0.3)
previousImage(viewer)
waitFor("Manual previous image loads during slideshow") { loaded(viewer, first) }
expect(viewer.isSlideshowRunning, "Manual navigation preserves the slideshow playback intent")
pump(0.75)
expect(sameURL(viewer.selectedURL, first), "Manual navigation restarts a full per-image interval")
waitFor("Slideshow continues after manual navigation") { loaded(viewer, second) }
let decodeStartsBeforeSort = ImageDocument.starts.count
viewer.sortPicker.selectItem(at: 1)
send(viewer.sortPicker)
expect(sameURL(viewer.selectedURL, second) && viewer.canvas.image != nil, "Sorting a running slideshow preserves the current image")
expect(ImageDocument.starts.count == decodeStartsBeforeSort, "Sorting does not decode the current image again")
expect(viewer.files.map(\.name) == ["30.png", "2.png", "10.png"], "Size sorting uses real filesystem metadata")
waitFor("Loop follows the new sorted order") { loaded(viewer, third) }
send(viewer.slideshowButton)

viewer.open(urls: [first, second, third])
waitFor("Fresh selection is ready") { loaded(viewer, first) && viewer.slideshowButton.isEnabled }
expect(!viewer.isSlideshowRunning, "Opening a new selection clears previous slideshow intent")
viewer.setSlideshowInterval(1)
send(viewer.slideshowButton)
pump(0.2)
viewer.setSlideshowInterval(0.5)
waitFor("Shorter interval applies while running") { loaded(viewer, second) }
viewer.setSlideshowInterval(1.2)
pump(0.7)
expect(viewer.selectedURL == second, "Longer interval replaces the old timer immediately")
waitFor("Longer interval eventually advances") { loaded(viewer, third) }
send(viewer.slideshowButton)

viewer.open(urls: [first, second])
waitFor("Two image list is ready") { loaded(viewer, first) && viewer.slideshowButton.isEnabled }
viewer.setSlideshowInterval(0.5)
viewer.loopSlideshowButton.state = .off
send(viewer.loopSlideshowButton)
send(viewer.slideshowButton)
waitFor("Nonlooping slideshow reaches the last image") { loaded(viewer, second) }
waitFor("Nonlooping slideshow stops at the end") { !viewer.isSlideshowRunning }
pump(0.6)
expect(viewer.selectedURL == second, "Nonlooping slideshow keeps its final image visible")
viewer.loopSlideshowButton.state = .on
send(viewer.loopSlideshowButton)

let slow = try fixture("2-slow.png", directory: "slow")
let afterSlow = try fixture("3.png", directory: "slow")
let beforeSlow = try fixture("1.png", directory: "slow")
viewer.open(urls: [beforeSlow, slow, afterSlow])
waitFor("Slow image sequence is ready") { loaded(viewer, beforeSlow) && viewer.slideshowButton.isEnabled }
send(viewer.slideshowButton)
waitFor("Slideshow begins slow image decoding") { viewer.selectedURL == slow && viewer.canvas.image == nil }
pump(0.65)
expect(viewer.selectedURL == slow && viewer.canvas.image == nil && viewer.isSlideshowRunning,
       "Slow decode is not cancelled when a slide interval elapses")
waitFor("Slow image finally becomes visible") { loaded(viewer, slow) }
pump(0.3)
expect(viewer.selectedURL == slow, "Decoded slow image receives its full display interval")
waitFor("Slideshow advances after slow image was displayed") { loaded(viewer, afterSlow) }
send(viewer.slideshowButton)

let slowStartsBeforeOpen = ImageDocument.starts.filter { sameURL($0, slow) }.count
viewer.open(urls: [slow])
waitFor("Slow initial image decode begins") { ImageDocument.starts.filter { sameURL($0, slow) }.count > slowStartsBeforeOpen }
waitFor("Folder list is available while the first image is still decoding") {
  viewer.files.count == 3 && viewer.slideshowButton.isEnabled && viewer.canvas.image == nil
}
send(viewer.slideshowButton)
expect(viewer.isSlideshowRunning, "User can request slideshow while the first image is still decoding")
waitFor("Pending first image becomes visible") { loaded(viewer, slow) }
pump(0.3)
expect(viewer.selectedURL == slow, "Starting during initial decode still gives the first image its full dwell")
waitFor("Slideshow requested during initial decode advances normally") { loaded(viewer, afterSlow) }
send(viewer.slideshowButton)

let animation = try fixture("animation.gif", directory: "animation")
viewer.open(urls: [animation, first])
waitFor("Animation starts independently") { loaded(viewer, animation) && viewer.isAnimating && viewer.slideshowButton.isEnabled }
viewer.setSlideshowInterval(1)
send(viewer.slideshowButton)
pump(0.2)
expect(viewer.isSlideshowRunning && viewer.isAnimating, "Animation and slideshow playback coexist")
send(viewer.slideshowButton)
expect(!viewer.isSlideshowRunning && viewer.isAnimating, "Pausing slideshow does not stop the current animated image")
send(viewer.slideshowButton)
send(viewer.animationButton)
expect(viewer.isSlideshowRunning && !viewer.isAnimating, "Pausing an animation does not pause the slideshow")
waitFor("Slideshow advances from a paused animated image") { loaded(viewer, first) }
send(viewer.slideshowButton)

let lagAnimation = try fixture("lag-animation.gif", directory: "animation")
viewer.open(urls: [lagAnimation, first])
waitFor("Slow subsequent animation frame is being decoded") {
  loaded(viewer, lagAnimation) && ImageDocument.pendingFrames.contains(lagAnimation) && viewer.slideshowButton.isEnabled
}
viewer.setSlideshowInterval(0.5)
send(viewer.slideshowButton)
expect(viewer.isSlideshowRunning && viewer.isAnimating, "Slideshow can start while an already-visible animation decodes its next frame")
waitFor("Pending animation frame cannot leave slideshow without a deadline") { loaded(viewer, first) }
send(viewer.slideshowButton)

viewer.open(urls: [first, second])
waitFor("Minimization sequence is ready") { loaded(viewer, first) && viewer.slideshowButton.isEnabled }
viewer.setSlideshowInterval(0.5)
send(viewer.slideshowButton)
viewer.window?.miniaturize(nil)
waitFor("Image window minimizes") { viewer.window?.isMiniaturized == true }
let minimizedURL = viewer.selectedURL
pump(0.8)
expect(viewer.selectedURL == minimizedURL, "Minimized slideshow does not advance in the background")
viewer.window?.deminiaturize(nil)
waitFor("Image window restores") { viewer.window?.isMiniaturized == false }
pump(0.2)
expect(viewer.selectedURL == minimizedURL, "Restoring does not immediately catch up an overdue slide")
waitFor("Restored slideshow starts a fresh interval") { viewer.selectedURL != minimizedURL }
send(viewer.slideshowButton)

viewer.open(urls: [first, second])
waitFor("Confirmation sequence is ready") { loaded(viewer, first) && viewer.convertButton.isEnabled && viewer.slideshowButton.isEnabled }
send(viewer.slideshowButton)
send(viewer.convertButton)
waitFor("Conversion confirmation appears") { viewer.window?.attachedSheet != nil }
expect(!viewer.isSlideshowRunning, "Conversion confirmation stops the slideshow")
pump(0.7)
expect(viewer.selectedURL == first, "An attached confirmation sheet keeps its source image selected")
dismissSheet(viewer)
expect(!viewer.isSlideshowRunning, "Cancelling conversion confirmation does not restart slideshow unexpectedly")
send(viewer.slideshowButton)
viewer.beginConversion(url: first, format: .png, frameIndex: nil)
expect(viewer.isBusy && !viewer.isSlideshowRunning, "Direct conversion entry also stops slideshow")
expect(!viewer.slideshowButton.isEnabled, "Slideshow cannot restart during an active conversion")
pump(0.6)
expect(viewer.selectedURL == first, "Background conversion is not raced by slideshow navigation")
waitFor("Conversion completes normally") { !viewer.isBusy }

let bad = try fixture("bad.png", directory: "failure")
viewer.open(urls: [bad, first])
waitFor("Undecodable first image exposes slideshow controls") {
  viewer.selectedURL == bad && viewer.canvas.image == nil && viewer.slideshowButton.isEnabled
}
send(viewer.slideshowButton)
pump(0.3)
expect(viewer.selectedURL == bad && !viewer.statusLabel.stringValue.isEmpty, "Broken image failure remains visible before it is skipped")
waitFor("Broken image is skipped automatically") { loaded(viewer, first) }
expect(viewer.isSlideshowRunning, "Slideshow continues after a single broken image")
send(viewer.slideshowButton)
let anotherBad = try fixture("another-bad.png", directory: "failure")
viewer.open(urls: [bad, anotherBad])
waitFor("All-broken selection is ready") { viewer.selectedURL == bad && viewer.slideshowButton.isEnabled }
send(viewer.slideshowButton)
waitFor("All-broken slideshow terminates instead of looping forever") { !viewer.isSlideshowRunning }
let failuresBeforeWait = ImageDocument.starts.count
pump(1)
expect(ImageDocument.starts.count == failuresBeforeWait, "All-broken termination cancels future timers")

let alone = try fixture("only.png", directory: "alone")
viewer.open(urls: [alone])
waitFor("Single-file directory loads") { loaded(viewer, alone) && viewer.files.count == 1 }
pump(0.1)
expect(!viewer.slideshowButton.isEnabled && !viewer.isSlideshowRunning, "A one-image directory does not start an endless slideshow")
let remaining = try fixture("1.png", directory: "shrinking")
let removed = try fixture("2.png", directory: "shrinking")
viewer.open(urls: [remaining])
waitFor("Two-image folder is ready before an external removal") {
  loaded(viewer, remaining) && viewer.files.count == 2 && viewer.slideshowButton.isEnabled
}
viewer.setSlideshowInterval(0.5)
send(viewer.slideshowButton)
try FileManager.default.removeItem(at: removed)
viewer.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: viewer.window))
waitFor("Folder refresh removes an externally deleted sibling") { viewer.files.count == 1 }
expect(!viewer.isSlideshowRunning && !viewer.slideshowButton.isEnabled, "Slideshow stops when its refreshed folder contains only one image")
let startsAfterShrinking = ImageDocument.starts.count
pump(0.7)
expect(ImageDocument.starts.count == startsAfterShrinking && loaded(viewer, remaining),
       "Single-image refresh keeps the current pixels without repeatedly decoding the same slide")
let explicitLarge = try fixture("large.png", directory: "explicit-refresh", bytes: 4000)
let explicitSmall = try fixture("small.png", directory: "explicit-refresh", bytes: 2000)
viewer.open(urls: [explicitLarge, explicitSmall])
waitFor("Explicit selection loads its real metadata") {
  loaded(viewer, explicitLarge) && viewer.files.first?.fileSize == 4000 && viewer.slideshowButton.isEnabled
}
try Data(repeating: 0, count: 3000).write(to: explicitLarge)
viewer.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: viewer.window))
waitFor("Unsorted explicit selection refreshes changed metadata") { viewer.files.first?.fileSize == 3000 }
expect(viewer.files.map(\.url) == [explicitLarge, explicitSmall], "Refreshing preserves explicit selection order until the user requests sorting")
viewer.sortPicker.selectItem(at: 1)
send(viewer.sortPicker)
expect(viewer.files.map(\.url) == [explicitSmall, explicitLarge], "User-requested size ordering applies to explicit selections")
let decodesBeforeExplicitRefresh = ImageDocument.starts.count
try Data([0]).write(to: explicitLarge)
viewer.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: viewer.window))
waitFor("Explicit size sorting is reapplied after Finder changes a file") {
  viewer.files.first?.url == explicitLarge && viewer.files.first?.fileSize == 1
}
expect(viewer.selectedURL == explicitLarge && viewer.tableView.selectedRow == 0 && viewer.canvas.image != nil,
       "Reordering refreshed explicit files preserves the current image and selected row")
expect(ImageDocument.starts.count == decodesBeforeExplicitRefresh, "Explicit metadata refresh does not re-decode the displayed image")
viewer.open(urls: [first, second])
waitFor("Close sequence is ready") { loaded(viewer, first) && viewer.slideshowButton.isEnabled }
send(viewer.slideshowButton)
viewer.cancelAndClose()
pump(0.7)
expect(!viewer.isSlideshowRunning && viewer.canvas.image == nil && viewer.window?.isVisible == false,
       "Closing clears slideshow state and visible pixels")
viewer.open(urls: [first, second])
viewer.showWindow(nil)
waitFor("Closed image window can reopen") { loaded(viewer, first) && viewer.window?.isVisible == true }
pump(0.7)
expect(!viewer.isSlideshowRunning && viewer.selectedURL == first, "Reopening does not restore an old slideshow timer")
let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                               timestamp: 0, windowNumber: viewer.window!.windowNumber, context: nil,
                               characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)!
viewer.canvas.keyDown(with: shortcut)
expect(viewer.isSlideshowRunning, "The S shortcut starts slideshow from the image canvas")
viewer.canvas.keyDown(with: shortcut)
expect(!viewer.isSlideshowRunning, "The S shortcut pauses slideshow without changing the selected image")
viewer.setSlideshowInterval(7.5)
viewer.loopSlideshowButton.state = .off
send(viewer.loopSlideshowButton)
let restored = ImageViewerWindowController(urls: [first, second], defaults: defaults)
expect(restored.slideshowInterval == 7.5 && restored.loopSlideshowButton.state == .off,
       "Interval and loop preference persist only in the injected settings suite")
expect(!restored.isSlideshowRunning, "Persisted preferences never auto-start slideshow")
restored.cancelAndClose()
viewer.cancelAndClose()

print("Image slideshow UI checks passed: \(checks)")
