import Cocoa

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  checks += 1
  if !condition() { fputs("Check failed: \(message)\n", stderr); exit(1) }
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
func waitFor(_ message: String, _ condition: () -> Bool) {
  let deadline = Date().addingTimeInterval(5)
  while !condition() && Date() < deadline { pump() }
  expect(condition(), message)
}
final class FrameWrapGate {
  private let lock = NSLock()
  private let release = DispatchSemaphore(value: 0)
  private var zeroRequests = 0
  private var blocked = false
  private var timedOut = false
  var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
  var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
  func observe(_ index: Int) {
    guard index == 0 else { return }
    lock.lock()
    zeroRequests += 1
    let shouldBlock = zeroRequests == 2
    if shouldBlock { blocked = true }
    lock.unlock()
    if shouldBlock && release.wait(timeout: .now() + 5) == .timedOut {
      lock.lock(); timedOut = true; lock.unlock()
    }
  }
  func resume() { release.signal() }
}
func textContent(_ view: NSView) -> String {
  let own = (view as? NSTextField)?.stringValue ?? ""
  return ([own] + view.subviews.map(textContent)).joined(separator: "\n")
}
func dismissSheet(_ viewer: ImageViewerWindowController) {
  if let sheet = viewer.window?.attachedSheet {
    viewer.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    sheet.orderOut(nil)
    pump()
  }
}
func key(_ viewer: ImageViewerWindowController, code: UInt16, characters: String,
         modifiers: NSEvent.ModifierFlags = []) {
  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                             timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: viewer.window!.windowNumber, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: code)!
  viewer.window!.sendEvent(event)
}
func viewingMenu(_ viewer: ImageViewerWindowController) -> NSMenu {
  let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: viewer.window!.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
  return viewer.canvas.menu(for: event)!
}
@discardableResult
func mouse(_ viewer: ImageViewerWindowController, type: NSEvent.EventType = .leftMouseDown,
           point: CGPoint? = nil, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
  let canvas = viewer.canvas
  let location = canvas.convert(point ?? CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil)
  let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: viewer.window!.windowNumber, context: nil,
                               eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
  viewer.window!.sendEvent(event)
  return event
}
func sendMenuItem(_ item: NSMenuItem) {
  expect(item.isEnabled && item.action != nil, "Requested canvas menu action is available")
  NSApp.sendAction(item.action!, to: item.target, from: item)
}
func sameRect(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
  abs(lhs.minX - rhs.minX) < 0.5 && abs(lhs.minY - rhs.minY) < 0.5 &&
    abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
}
func capturePureViewing(_ viewer: ImageViewerWindowController, _ name: String) throws {
  guard let directory = ProcessInfo.processInfo.environment["IMAGE_PURE_VIEW_SCREENSHOT_DIR"],
        let window = viewer.window else { return }
  let output = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name + ".png")
  let capture = Process()
  capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
  capture.arguments = ["-x", "-l", String(window.windowNumber), "-o", output.path]
  try capture.run()
  capture.waitUntilExit()
  expect(capture.terminationStatus == 0, "The synthetic pure-view fixture window can be captured")
  print("Pure viewing screenshot: \(output.path)")
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.finishLaunching()
let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengying-image-ui-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let names = ["10.png", "2.png", "finite.gif", "pages.tiff", "slow.png"]
for name in names { try Data([0]).write(to: root.appendingPathComponent(name)) }
let url = root.appendingPathComponent("2.png")
let preferenceDomain = "io.chengying.tests.image-ui.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: preferenceDomain)!
defer { defaults.removePersistentDomain(forName: preferenceDomain) }
let viewer = ImageViewerWindowController(urls: [url], defaults: defaults)
let reusableCell = ImageFileListCell()
let taggedMetadata = PlaylistFileMetadata(url: url, fileSize: 1234,
  modificationDate: Date(timeIntervalSince1970: 123456), creationDate: Date(timeIntervalSince1970: 654321),
  tags: [PlaylistFileTag(name: "FixtureTag", colorIndex: 6)])
reusableCell.configure(taggedMetadata, showCreated: false)
let originalCellViews = reusableCell.subviews
let originalCellConstraints = reusableCell.constraints
expect(textContent(reusableCell).contains("FixtureTag") && reusableCell.toolTip?.contains("修改：") == true,
       "Reusable image cells show Finder tags and both dates")
let replacementMetadata = PlaylistFileMetadata(url: root.appendingPathComponent("Replacement.png"))
reusableCell.configure(replacementMetadata, showCreated: true)
expect(reusableCell.subviews == originalCellViews && reusableCell.constraints == originalCellConstraints,
       "Row configuration reuses its view and constraint identities")
expect(reusableCell.textField?.stringValue == "Replacement.png" &&
       textContent(reusableCell).contains("创建 未知") && textContent(reusableCell).contains("无 Finder 标签") &&
       !textContent(reusableCell).contains("FixtureTag") && reusableCell.toolTip?.contains("FixtureTag") == false,
       "Reused rows replace names, tags, unknown dates and tooltips without stale content")
if ProcessInfo.processInfo.environment["CHENGYING_PERFORMANCE_BENCHMARK"] == "1" {
  let iterations = 1000
  let freshStart = CACurrentMediaTime()
  for _ in 0..<iterations {
    autoreleasepool { ImageFileListCell().configure(taggedMetadata, showCreated: false) }
  }
  let freshTime = (CACurrentMediaTime() - freshStart) * 1000
  let reuseStart = CACurrentMediaTime()
  for _ in 0..<iterations { autoreleasepool { reusableCell.configure(taggedMetadata, showCreated: false) } }
  print(String(format: "PERF image-list-cell count=%d fresh_ms=%.3f reused_ms=%.3f",
               iterations, freshTime, (CACurrentMediaTime() - reuseStart) * 1000))
}
viewer.showWindow(nil)
viewer.window?.makeKeyAndOrderFront(nil)
NSApp.activate(ignoringOtherApps: true)
waitFor("Initial image loaded") { viewer.canvas.image != nil && viewer.files.count == names.count }
expect(viewer.files.filter { $0.name == "2.png" }.count == 1, "Symlinked parent path does not duplicate current file")
expect(viewer.files.first?.name == "2.png", "Sibling names use natural order")
expect(viewer.selectedURL == url, "Selected file survives directory enumeration")
expect(viewer.window?.title.contains("澄影视界") == true, "Image window uses current app branding")
expect(viewer.window?.firstResponder === viewer.canvas, "New image window directs keyboard input to the canvas")
expect(viewer.canvas.bounds.width > 300 && viewer.canvas.bounds.height > 200, "Canvas receives usable layout")
viewer.canvas.actualSize()
expect(abs(viewer.canvas.imageRect.width * viewer.canvas.backingScale - 240) < 0.001, "100 percent uses physical pixels")
let anchor = CGPoint(x: viewer.canvas.bounds.midX + 25, y: viewer.canvas.bounds.midY + 10)
let before = viewer.canvas.imageRect
let pixel = CGPoint(x: (anchor.x - before.minX) / before.width, y: (anchor.y - before.minY) / before.height)
viewer.canvas.setZoom(2, anchor: anchor)
let after = viewer.canvas.imageRect
expect(abs(after.minX + pixel.x * after.width - anchor.x) < 0.001, "Zoom preserves horizontal anchor")
expect(abs(after.minY + pixel.y * after.height - anchor.y) < 0.001, "Zoom preserves vertical anchor")
viewer.canvas.setZoom(.infinity)
expect(viewer.canvas.zoom == 2, "Invalid zoom rejected")
viewer.canvas.fitToWindow()
expect(viewer.canvas.fitsWindow && viewer.canvas.imageOffset == .zero, "Fit resets pan")
let previousZoom = viewer.canvas.zoom
viewer.canvas.display(viewer.canvas.image, resetZoom: false)
expect(viewer.canvas.zoom == previousZoom, "Animation frame does not change zoom")
viewer.sortPicker.selectItem(at: 1)
NSApp.sendAction(viewer.sortPicker.action!, to: viewer.sortPicker.target, from: viewer.sortPicker)
expect(viewer.selectedURL == url, "Sorting preserves selected image")
let frame = viewer.window!.frame
viewer.window?.setContentSize(NSSize(width: 880, height: 620))
pump()
expect(viewer.canvas.bounds.width > 300 && viewer.canvas.bounds.height > 200, "Minimum window remains usable")
expect(!viewer.canvas.hasAmbiguousLayout, "Canvas layout is determined")
expect(viewer.nextButton.visibleRect.width > 20 && viewer.nextButton.visibleRect.height > 10, "Navigation controls are visible")
expect(viewer.convertButton.visibleRect.width > 20 && viewer.convertButton.visibleRect.height > 10, "Conversion controls are visible")
let imageWindow = viewer.window!
let contentView = imageWindow.contentView!
pump()
try capturePureViewing(viewer, "normal-minimum")
let normalCanvasFrame = viewer.canvas.convert(viewer.canvas.bounds, to: contentView)
let normalStyle = imageWindow.styleMask
let normalTitleVisibility = imageWindow.titleVisibility
let normalTitlebarTransparency = imageWindow.titlebarAppearsTransparent
let windowButtons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton, .documentIconButton]
let normalButtonVisibility = windowButtons.map { imageWindow.standardWindowButton($0)?.isHidden }
let normalWindowFrame = imageWindow.frame
let normalMinimumContentSize = imageWindow.contentMinSize
let normalAspectRatio = imageWindow.contentAspectRatio
let normalAutosaveName = imageWindow.frameAutosaveName
expect(viewer.pureViewingButton.isEnabled && !viewer.isPureViewing,
       "A decoded image offers pure viewing without enabling it automatically")
viewer.pureViewingButton.performClick(nil)
pump()
expect(viewer.isPureViewing && viewer.canvas.isPureViewing,
       "The visible toolbar control enables pure viewing")
expect(sameRect(viewer.canvas.convert(viewer.canvas.bounds, to: contentView), contentView.bounds),
       "Pure viewing fills the entire content area without toolbar, sidebar, footer, or margins")
expect([viewer.pureViewingButton, viewer.sidebarPicker, viewer.nextButton, viewer.statusLabel]
  .allSatisfy { $0.isHiddenOrHasHiddenAncestor }, "Every image viewing chrome region is hidden")
expect(imageWindow.styleMask.contains(.titled) && imageWindow.styleMask.contains(.fullSizeContentView) &&
       imageWindow.styleMask.contains(.fullScreen) == normalStyle.contains(.fullScreen),
       "Pure viewing preserves a titled key window and does not enter macOS fullscreen")
expect(imageWindow.titleVisibility == .hidden && imageWindow.titlebarAppearsTransparent &&
       windowButtons.allSatisfy { imageWindow.standardWindowButton($0).map { $0.isHidden } ?? true },
       "Pure viewing removes the native title, traffic lights, and document proxy icon")
try capturePureViewing(viewer, "pure-minimum")
expect(imageWindow.firstResponder === viewer.canvas && imageWindow.isKeyWindow,
       "Pure viewing keeps the canvas ready for keyboard navigation")
print("Pure layout frame=\(imageWindow.frame) content=\(contentView.bounds) canvas=\(viewer.canvas.bounds) image=\(viewer.canvas.imageRect)")
expect(viewer.canvas.fitsWindow &&
       (abs(viewer.canvas.imageRect.width - viewer.canvas.bounds.width) < 0.5 &&
        abs(viewer.canvas.imageRect.height - viewer.canvas.bounds.height) < 0.5),
       "Pure fit matches both window dimensions without letterboxing, stretching, or cropping")
expect(imageWindow.frameAutosaveName.isEmpty, "Pure-view resizing cannot overwrite the normal saved frame")
let pureMenu = viewingMenu(viewer)
expect(pureMenu.items.first?.title.contains("退出") == true && pureMenu.items[1].title == "全屏",
       "Right-click exposes pure-view exit separately from macOS fullscreen")
sendMenuItem(pureMenu.items[0])
pump()
expect(!viewer.isPureViewing && !viewer.canvas.isPureViewing &&
       sameRect(viewer.canvas.convert(viewer.canvas.bounds, to: contentView), normalCanvasFrame),
       "Right-click exit restores the exact normal canvas layout")
expect(imageWindow.styleMask == normalStyle && imageWindow.titleVisibility == normalTitleVisibility &&
       imageWindow.titlebarAppearsTransparent == normalTitlebarTransparency &&
       windowButtons.map { imageWindow.standardWindowButton($0)?.isHidden } == normalButtonVisibility,
       "Exit restores the previous native window appearance")
expect([viewer.pureViewingButton, viewer.sidebarPicker, viewer.nextButton, viewer.statusLabel]
  .allSatisfy { !$0.isHiddenOrHasHiddenAncestor }, "Exit restores all three chrome regions")
expect(sameRect(imageWindow.frame, normalWindowFrame) && imageWindow.contentMinSize == normalMinimumContentSize &&
       imageWindow.contentAspectRatio == normalAspectRatio && imageWindow.frameAutosaveName == normalAutosaveName,
       "Exit restores the normal frame, size policy, and autosave identity")
try capturePureViewing(viewer, "restored-minimum")

viewer.canvas.setZoom(2)
let dragStart = viewer.canvas.convert(CGPoint(x: viewer.canvas.bounds.midX, y: viewer.canvas.bounds.midY), to: nil)
for (type, location) in [(NSEvent.EventType.leftMouseDown, dragStart),
                         (.leftMouseDragged, CGPoint(x: dragStart.x + 37, y: dragStart.y - 21))] {
  let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                               windowNumber: imageWindow.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
  if type == .leftMouseDown { viewer.canvas.mouseDown(with: event) }
  else { viewer.canvas.mouseDragged(with: event) }
}
let manualZoom = viewer.canvas.zoom
let manualOffset = viewer.canvas.imageOffset
expect(manualOffset != .zero && !viewer.canvas.fitsWindow, "Mouse dragging establishes a manual image position")
key(viewer, code: 48, characters: "\t")
pump()
expect(viewer.isPureViewing && viewer.canvas.fitsWindow && viewer.canvas.imageOffset == .zero &&
       abs(viewer.canvas.imageRect.width - viewer.canvas.bounds.width) < 0.51 &&
       abs(viewer.canvas.imageRect.height - viewer.canvas.bounds.height) < 0.51,
       "Pure viewing starts with the whole image fitted rather than inheriting an inspection offset")
let directFrame = imageWindow.frame
let originalMoveHandler = viewer.canvas.onMoveWindow
var forwardedMouseDown: NSEvent?
viewer.canvas.onMoveWindow = { event in forwardedMouseDown = event; originalMoveHandler?(event) }
let nativeDown = mouse(viewer)
mouse(viewer, type: .leftMouseDragged,
      point: CGPoint(x: viewer.canvas.bounds.midX + 30, y: viewer.canvas.bounds.midY - 20))
mouse(viewer, type: .leftMouseUp)
pump(0.15)
expect(forwardedMouseDown === nativeDown && viewer.canvas.imageOffset == .zero && viewer.canvas.fitsWindow,
       "Window-routed left drag delegates the original event to AppKit without accidentally panning the image")
viewer.canvas.onMoveWindow = originalMoveHandler
// Synthetic AppKit events cannot drive WindowServer movement without event-injection permission.
// Native drag dispatch is covered here; physical edge/corner resizing remains a manual acceptance check.
expect(imageWindow.styleMask.contains([.titled, .resizable]) &&
       !imageWindow.isMovableByWindowBackground && imageWindow.contentAspectRatio == NSSize(width: 240, height: 120),
       "The native titled resizable window retains its aspect-locked edges and corners")
mouse(viewer, modifiers: [.option])
mouse(viewer, type: .leftMouseDragged,
      point: CGPoint(x: viewer.canvas.bounds.midX + 30, y: viewer.canvas.bounds.midY - 20), modifiers: [.option])
mouse(viewer, type: .leftMouseUp, modifiers: [.option])
expect(viewer.canvas.imageOffset == CGPoint(x: 30, y: -20) && !viewer.canvas.fitsWindow &&
       sameRect(imageWindow.frame, directFrame), "Option-drag explicitly pans image details without moving the window")
mouse(viewer)
mouse(viewer, type: .leftMouseUp)
mouse(viewer, clicks: 2)
mouse(viewer, type: .leftMouseUp, clicks: 2)
pump()
let visiblePureScreen = imageWindow.screen!.visibleFrame
expect(viewer.canvas.fitsWindow && viewer.canvas.imageOffset == .zero &&
       visiblePureScreen.insetBy(dx: -1, dy: -1).contains(imageWindow.frame) &&
       (abs(imageWindow.frame.width - visiblePureScreen.width) < 2 ||
        abs(imageWindow.frame.height - visiblePureScreen.height) < 2),
       "A window-routed double click maximizes the complete image inside the current screen")
expect(viewingMenu(viewer).items[2].title.contains("恢复"), "The right-click menu exposes maximum-fit restoration")
let maximizedFrame = imageWindow.frame
pump(0.15)
expect(imageWindow.frame == maximizedFrame, "A stale native-drag release timer cannot undo fast double-click maximization")
mouse(viewer, clicks: 2)
mouse(viewer, type: .leftMouseUp, clicks: 2)
pump()
expect(sameRect(imageWindow.frame, directFrame), "A second double click restores the previous pure-view frame")
key(viewer, code: 27, characters: "-")
expect(imageWindow.frame.width < directFrame.width && viewer.canvas.fitsWindow && viewer.canvas.imageOffset == .zero,
       "Pure-view minus resizes the image window while preserving centered fit")
key(viewer, code: 24, characters: "+")
expect(abs(imageWindow.frame.width - directFrame.width) < 3 && viewer.canvas.fitsWindow,
       "Pure-view plus increases the proportional image window rather than magnifying into a black canvas")
mouse(viewer, clicks: 2)
mouse(viewer, type: .leftMouseUp, clicks: 2)
imageWindow.setContentSize(NSSize(width: directFrame.width / 2, height: directFrame.height / 2))
viewer.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: imageWindow))
expect(viewingMenu(viewer).items[2].title.contains("最大") && viewer.canvas.fitsWindow &&
       abs(viewer.canvas.imageRect.width - viewer.canvas.bounds.width) < 0.51 &&
       abs(viewer.canvas.imageRect.height - viewer.canvas.bounds.height) < 0.51,
       "A native resize completion retires the previous maximum-fit restore frame and refits the image")
key(viewer, code: 53, characters: "\u{1b}")
pump()
expect(!viewer.isPureViewing && viewer.canvas.zoom == manualZoom && viewer.canvas.imageOffset == manualOffset &&
       imageWindow.firstResponder === viewer.canvas, "Escape restores chrome and retains zoom, pan, and canvas focus")
let syntheticOtherScale = ImageCanvasView.ViewportState(zoom: manualZoom, offset: manualOffset,
                                                       fitsWindow: false, backingScale: viewer.canvas.backingScale * 2)
viewer.canvas.restoreViewport(syntheticOtherScale)
expect(viewer.canvas.zoom == manualZoom && viewer.canvas.imageOffset == CGPoint(x: manualOffset.x * 2, y: manualOffset.y * 2),
       "Restoring a viewport across backing scales preserves pixel zoom and converts point offsets")
viewer.canvas.restoreViewport(ImageCanvasView.ViewportState(zoom: manualZoom, offset: manualOffset,
                                                           fitsWindow: false, backingScale: viewer.canvas.backingScale))
sendMenuItem(viewingMenu(viewer).items[0])
expect(viewer.isPureViewing, "Right-click can also enter pure viewing")
key(viewer, code: 48, characters: "\t")
expect(!viewer.isPureViewing, "Tab toggles pure viewing off through normal window event routing")
let pureUpdateOwner = UUID()
key(viewer, code: 48, characters: "\t")
expect(UpdateWorkAdmission.shared.acquire(pureUpdateOwner), "Idle pure viewing permits an update admission barrier")
key(viewer, code: 53, characters: "\u{1b}")
expect(!viewer.isPureViewing, "Escape remains usable when a new update barrier prevents entry")
key(viewer, code: 48, characters: "\t")
expect(!viewer.isPureViewing && viewingMenu(viewer).items[0].isEnabled == false,
       "Keyboard and menu entry obey the update admission barrier")
UpdateWorkAdmission.shared.release(pureUpdateOwner)
viewer.canvas.fitToWindow()
if ProcessInfo.processInfo.environment["IMAGE_VIEWER_TEST_FULLSCREEN"] == "1" {
  var enteredFullscreen = 0
  var exitedFullscreen = 0
  let enteredObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
    object: imageWindow, queue: .main) { _ in enteredFullscreen += 1 }
  let exitedObserver = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
    object: imageWindow, queue: .main) { _ in exitedFullscreen += 1 }
  imageWindow.toggleFullScreen(nil)
  waitFor("Normal baseline enters AppKit fullscreen") { enteredFullscreen == 1 }
  imageWindow.toggleFullScreen(nil)
  waitFor("Normal baseline exits AppKit fullscreen") { exitedFullscreen == 1 }
  let fullscreenButtonVisibility = windowButtons.map { imageWindow.standardWindowButton($0)?.isHidden }
  key(viewer, code: 48, characters: "\t")
  imageWindow.toggleFullScreen(nil)
  waitFor("Pure viewing enters actual AppKit fullscreen") { enteredFullscreen == 2 }
  pump(0.1)
  expect(viewer.isPureViewing && imageWindow.styleMask.contains(.fullScreen) &&
         sameRect(viewer.canvas.convert(viewer.canvas.bounds, to: contentView), contentView.bounds),
         "Pure viewing remains edge-to-edge after a native fullscreen transition")
  let fullFrame = imageWindow.frame
  let fullZoom = viewer.canvas.zoom
  key(viewer, code: 27, characters: "-")
  expect(imageWindow.frame == fullFrame && !viewer.canvas.fitsWindow &&
         abs(viewer.canvas.zoom - fullZoom / 1.25) < 0.001,
         "Pure native fullscreen falls back to local zoom because its window cannot be resized")
  key(viewer, code: 29, characters: "0")
  mouse(viewer, clicks: 2)
  mouse(viewer, type: .leftMouseUp, clicks: 2)
  expect(imageWindow.frame == fullFrame && viewer.canvas.fitsWindow,
         "Double-click maximization does not interfere with native fullscreen")
  key(viewer, code: 53, characters: "\u{1b}")
  expect(!viewer.isPureViewing && imageWindow.styleMask.contains(.fullScreen),
         "Escape exits pure viewing while preserving actual macOS fullscreen")
  imageWindow.toggleFullScreen(nil)
  waitFor("Normal viewing exits actual AppKit fullscreen") { exitedFullscreen == 2 }
  imageWindow.toggleFullScreen(nil)
  waitFor("Normal viewing can enter actual AppKit fullscreen first") { enteredFullscreen == 3 }
  key(viewer, code: 48, characters: "\t")
  expect(viewer.isPureViewing && imageWindow.styleMask.contains(.fullScreen),
         "Pure viewing can start inside an existing fullscreen window")
  imageWindow.toggleFullScreen(nil)
  waitFor("Pure viewing survives leaving actual AppKit fullscreen") { exitedFullscreen == 3 }
  expect(viewer.isPureViewing && !imageWindow.styleMask.contains(.fullScreen) &&
         windowButtons.allSatisfy { imageWindow.standardWindowButton($0).map { $0.isHidden } ?? true },
         "Leaving macOS fullscreen retains pure viewing and hides native titlebar buttons")
  key(viewer, code: 53, characters: "\u{1b}")
  pump()
  let restoredButtons = windowButtons.map { imageWindow.standardWindowButton($0)?.isHidden }
  expect(imageWindow.styleMask == normalStyle && imageWindow.titleVisibility == normalTitleVisibility &&
         imageWindow.titlebarAppearsTransparent == normalTitlebarTransparency &&
         restoredButtons == fullscreenButtonVisibility,
         "Both fullscreen transition orders restore the original window appearance")
  try capturePureViewing(viewer, "restored-after-fullscreen")
  let beforeFullscreenClose = imageWindow.frame
  let autosaveBeforeClose = imageWindow.frameAutosaveName
  key(viewer, code: 48, characters: "\t")
  imageWindow.toggleFullScreen(nil)
  waitFor("Pure viewing enters fullscreen before closing") { enteredFullscreen == 4 }
  viewer.cancelAndClose()
  waitFor("A pure fullscreen viewer closes without retaining active image state") {
    !imageWindow.isVisible && !viewer.isPureViewing && viewer.canvas.image == nil
  }
  viewer.open(urls: [url])
  viewer.showWindow(nil)
  imageWindow.makeKeyAndOrderFront(nil)
  waitFor("A closed fullscreen viewer can load an image again") { viewer.canvas.image != nil }
  if imageWindow.styleMask.contains(.fullScreen) { imageWindow.toggleFullScreen(nil) }
  waitFor("Reopened viewing completes any pending fullscreen exit") {
    !imageWindow.styleMask.contains(.fullScreen) && imageWindow.frameAutosaveName == autosaveBeforeClose
  }
  pump()
  expect(!viewer.isPureViewing && sameRect(imageWindow.frame, beforeFullscreenClose) &&
         imageWindow.contentMinSize == normalMinimumContentSize && imageWindow.contentAspectRatio == normalAspectRatio,
         "Closing and reopening a pure fullscreen viewer restores normal geometry and autosave")
  NotificationCenter.default.removeObserver(enteredObserver)
  NotificationCenter.default.removeObserver(exitedObserver)
} else {
  print("Native fullscreen transition checks skipped: set IMAGE_VIEWER_TEST_FULLSCREEN=1 with a WindowServer session")
}
viewer.window?.setFrame(frame, display: true)
pump()

viewer.editButton.performClick(nil)
expect(viewer.isEditingImage && viewer.canvas.cropEnabled && !viewer.editingPanel.isHidden,
       "Editor opens inside the native image window")
expect(viewer.isActiveForUpdate, "An editing session prevents automatic update installation")
expect(viewer.canvas.cropSelection == ImagePixelRect(x: 0, y: 0, width: 240, height: 120),
       "Editor starts with original pixel bounds")
expect(!viewer.nextButton.isEnabled && !viewer.slideshowButton.isEnabled,
       "Editing disables file navigation and slideshow")
viewer.canvas.onNavigate?(1)
viewer.canvas.onToggleSlideshow?()
expect(viewer.selectedURL == url && !viewer.isSlideshowRunning, "Canvas shortcuts obey the edit guard")
let panel = viewer.editingPanel
panel.ratioPicker.selectItem(at: 2)
NSApp.sendAction(panel.ratioPicker.action!, to: panel.ratioPicker.target, from: panel.ratioPicker)
expect(viewer.canvas.cropSelection?.width == 120 && viewer.canvas.cropSelection?.height == 120,
       "Square ratio uses source pixels, not screen points")
panel.rotateRightButton.performClick(nil)
waitFor("Rotated edit preview is ready") { !viewer.editPreviewPending }
expect(viewer.canvas.image?.width == 120 && viewer.canvas.image?.height == 240,
       "Rotation previews the original image at full resolution")
expect(panel.orientationPlan.quarterTurnsClockwise == 1 && viewer.canvas.cropSelection?.height == 120,
       "Rotation retains the crop ratio and resets its bounds")
panel.widthField.stringValue = "60"
NSApp.sendAction(panel.widthField.action!, to: panel.widthField.target, from: panel.widthField)
expect(panel.heightField.stringValue == "60", "Pixel resize maintains the selected crop aspect ratio")
let editedPlan = try panel.makePlan(crop: viewer.canvas.cropSelection)
expect(editedPlan.outputWidth == 60 && editedPlan.outputHeight == 60 && editedPlan.sourceWidth == 240,
       "Export plan records output pixels and original source dimensions")
let pureRejectedCrop = viewer.canvas.cropSelection
let pureRejectedImage = viewer.canvas.image
key(viewer, code: 48, characters: "\t")
viewer.canvas.onTogglePureViewing?()
expect(!viewer.isPureViewing && !viewer.pureViewingButton.isEnabled &&
       viewingMenu(viewer).items[0].isEnabled == false,
       "All pure-view entry paths reject an active image edit")
expect(viewer.isEditingImage && viewer.canvas.cropSelection == pureRejectedCrop &&
       viewer.canvas.image === pureRejectedImage && panel.widthField.stringValue == "60" &&
       panel.heightField.stringValue == "60" && panel.orientationPlan.quarterTurnsClockwise == 1,
       "Rejected pure viewing preserves the complete unsaved crop, resize, rotation, and preview")
panel.horizontalButton.performClick(nil)
waitFor("Flipped preview resets dimensions even if the crop rectangle is unchanged") { !viewer.editPreviewPending }
expect(panel.widthField.stringValue == "120" && panel.heightField.stringValue == "120",
       "An unchanged crop still synchronizes reset pixel fields")
panel.widthField.stringValue = "60"
NSApp.sendAction(panel.widthField.action!, to: panel.widthField.target, from: panel.widthField)
panel.heightField.stringValue = "not-a-size"
viewer.convertButton.performClick(nil)
expect(viewer.window?.attachedSheet == nil && viewer.statusLabel.stringValue.contains("整数"),
       "Invalid dimensions cannot start an export")
panel.heightField.stringValue = "60"
viewer.convertButton.performClick(nil)
waitFor("Edited output has a confirmation sheet") { viewer.window?.attachedSheet != nil }
expect(textContent(viewer.window!.attachedSheet!.contentView!).contains("60 × 60"),
       "Confirmation shows actual output pixel dimensions")
dismissSheet(viewer)
viewer.window?.setContentSize(NSSize(width: 880, height: 620))
pump()
expect(viewer.canvas.bounds.width > 300 && viewer.canvas.bounds.height > 140,
       "Editor leaves usable canvas space at minimum window size")
for control in [panel.rotateRightButton, panel.exitButton, panel.widthField, panel.heightField] as [NSView] {
  expect(control.visibleRect.width >= control.bounds.width - 1 && control.visibleRect.height > 10,
         "Editing controls remain visible at minimum window size")
}
viewer.window?.setFrame(frame, display: true)
if let screenshotPath = ProcessInfo.processInfo.environment["IMAGE_VIEWER_SCREENSHOT"],
   let view = viewer.window?.contentView,
   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
  view.cacheDisplay(in: view.bounds, to: bitmap)
  if let data = bitmap.representation(using: .png, properties: [:]) {
    try data.write(to: URL(fileURLWithPath: screenshotPath))
  }
  let capture = Process()
  capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
  capture.arguments = ["-l", String(viewer.window!.windowNumber), "-o", screenshotPath + ".window.png"]
  try? capture.run()
  capture.waitUntilExit()
}
panel.exitButton.performClick(nil)
expect(!viewer.isEditingImage && !viewer.canvas.cropEnabled && viewer.canvas.image?.width == 240,
       "Exiting editing restores original pixels and normal navigation")
waitFor("Preview activity releases its update lease") { UpdateWorkAdmission.shared.activeReasons.isEmpty }
expect(!viewer.isActiveForUpdate, "Finished editing no longer delays updates")
viewer.editButton.performClick(nil)
NSApp.sendAction(panel.rotateRightButton.action!, to: panel.rotateRightButton.target, from: panel.rotateRightButton)
expect(viewer.editPreviewPending, "Orientation preview runs asynchronously")
viewer.open(urls: [url, root.appendingPathComponent("pages.tiff")])
waitFor("Opening a new source invalidates an in-flight edit") {
  viewer.canvas.image?.width == 240 && !viewer.isEditingImage && !viewer.editPreviewPending
}
pump(0.1)
expect(viewer.canvas.image?.height == 120 && !viewer.canvas.cropEnabled,
       "Stale orientation preview cannot overwrite a newly opened source")

// Compare sequential UI operations against actual pixel transforms, not only checkbox state.
let editPixels = Data([255, 0, 0, 255, 0, 255, 0, 255,
                       0, 0, 255, 255, 255, 255, 0, 255,
                       255, 0, 255, 255, 0, 255, 255, 255])
let editSource = CGImage(width: 2, height: 3, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                        provider: CGDataProvider(data: editPixels as CFData)!, decode: nil,
                        shouldInterpolate: false, intent: .defaultIntent)!
for clockwise in [true, false] {
  let isolatedPanel = ImageEditingPanel(frame: .zero)
  isolatedPanel.configure(source: editSource)
  (clockwise ? isolatedPanel.horizontalButton : isolatedPanel.verticalButton).performClick(nil)
  (clockwise ? isolatedPanel.rotateRightButton : isolatedPanel.rotateLeftButton).performClick(nil)
  let actual = try ImageEditor.orientedImage(editSource, plan: isolatedPanel.orientationPlan)
  let first = try ImageEditor.orientedImage(editSource, plan: ImageEditPlan(flipHorizontal: clockwise, flipVertical: !clockwise))
  let expected = try ImageEditor.orientedImage(first, plan: ImageEditPlan(quarterTurnsClockwise: clockwise ? 1 : 3))
  expect(actual.dataProvider!.data! as Data == expected.dataProvider!.data! as Data,
         "Rotate after flip follows the user's operation order in actual pixels")
}

let explicit = [root.appendingPathComponent("pages.tiff"), url]
viewer.open(urls: explicit)
waitFor("Multi-selection preserved") { viewer.files.count == 2 && viewer.canvas.image != nil }
expect(viewer.files.map(\.url) == explicit, "Explicit selection does not grow or reorder")
expect(viewer.sortPicker.indexOfSelectedItem == 0, "New explicit selection resets stale sort label")
expect(viewer.frameIndex == 0, "Multi-page image starts at first page")
viewer.nextFrameButton.performClick(nil)
waitFor("Next page decoded") { viewer.frameIndex == 1 }
viewer.convertButton.performClick(nil)
waitFor("Single-page conversion requires confirmation") { viewer.window?.attachedSheet != nil }
viewer.canvas.onTogglePureViewing?()
expect(!viewer.isPureViewing && viewingMenu(viewer).items[0].isEnabled == false,
       "An attached conversion sheet prevents pure viewing")
expect(textContent(viewer.window!.attachedSheet!.contentView!).contains("仅导出当前第 2 页"), "Multi-page flattening warning names current page")
dismissSheet(viewer)
expect(!viewer.isBusy, "Cancelling confirmation does not start conversion")
viewer.previousFrameButton.performClick(nil)
waitFor("Previous page decoded") { viewer.frameIndex == 0 }
viewer.nextButton.performClick(nil)
waitFor("Next file loaded") { viewer.selectedURL == url && viewer.canvas.image != nil }
viewer.previousButton.performClick(nil)
waitFor("Previous file loaded") { viewer.selectedURL == explicit[0] && viewer.canvas.image != nil }

let animationURL = root.appendingPathComponent("finite.gif")
viewer.open(urls: [animationURL])
waitFor("Animated image starts") { viewer.isAnimating }
viewer.animationButton.performClick(nil)
let pausedImage = viewer.canvas.image
let pausedIndex = viewer.frameIndex
pump(0.2)
expect(!viewer.isAnimating && viewer.canvas.image != nil, "Pause retains visible frame")
expect(viewer.frameIndex == pausedIndex, "Paused animation stays on frame")
expect(pausedImage != nil, "Animation frame exists")
viewer.animationButton.performClick(nil)
waitFor("Finite animation stops") { !viewer.isAnimating && viewer.frameIndex == 2 }
expect(viewer.canvas.image != nil, "Last animation frame remains visible")
// performClick spins AppKit while flashing the button and can consume this entire
// short fixture. Dispatch the same action without hiding its first frame.
NSApp.sendAction(viewer.animationButton.action!, to: viewer.animationButton.target, from: viewer.animationButton)
waitFor("Completed finite animation restarts from first frame") { viewer.frameIndex == 0 && viewer.isAnimating }
waitFor("Replayed animation finishes its full sequence") { viewer.frameIndex == 2 && !viewer.isAnimating }
viewer.formatPicker.selectItem(at: ImageConversionFormat.allCases.firstIndex(of: .tiff)!)
viewer.convertButton.performClick(nil)
waitFor("Animated TIFF conversion requires confirmation") { viewer.window?.attachedSheet != nil }
expect(textContent(viewer.window!.attachedSheet!.contentView!).contains("多页静态图片"), "Animation to TIFF explicitly loses playback timing")
dismissSheet(viewer)

viewer.editButton.performClick(nil)
expect(viewer.isEditingImage && !viewer.isAnimating && !viewer.nextFrameButton.isEnabled,
       "Editing a GIF pauses animation and frame navigation")
viewer.canvas.onToggleAnimation?()
expect(!viewer.isAnimating, "Space cannot restart animation during editing")
viewer.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification))
viewer.windowDidDeminiaturize(Notification(name: NSWindow.didDeminiaturizeNotification))
expect(!viewer.isAnimating && viewer.isEditingImage, "Restoring a window does not restart an edited GIF")
viewer.convertButton.performClick(nil)
waitFor("Animation editing asks to preserve all frames") { viewer.window?.attachedSheet != nil }
expect(textContent(viewer.window!.attachedSheet!.contentView!).contains("全部 3 帧"),
       "Animation editing confirms that the same crop applies to every frame")
dismissSheet(viewer)
viewer.editButton.performClick(nil)

let triple = root.appendingPathComponent("triple.gif")
try Data([0]).write(to: triple)
var observedLoopStarts = 0
var lastObservedFrame = -1
let originalZoomCallback = viewer.canvas.onZoomChanged
viewer.canvas.onZoomChanged = { zoom in
  originalZoomCallback?(zoom)
  if viewer.canvas.image != nil && viewer.frameIndex != lastObservedFrame {
    lastObservedFrame = viewer.frameIndex
    if viewer.frameIndex == 0 { observedLoopStarts += 1 }
  }
}
viewer.open(urls: [triple, url])
waitFor("Finite animation reaches its second loop") { observedLoopStarts == 2 }
NSApp.sendAction(viewer.animationButton.action!, to: viewer.animationButton.target, from: viewer.animationButton)
expect(!viewer.isAnimating, "Finite animation pauses mid-sequence")
NSApp.sendAction(viewer.animationButton.action!, to: viewer.animationButton.target, from: viewer.animationButton)
waitFor("Finite animation resumes and completes") { !viewer.isAnimating && viewer.frameIndex == 2 }
expect(observedLoopStarts == 3, "Pause and resume do not reset completed finite loops")
viewer.canvas.onZoomChanged = originalZoomCallback

// Hold the first wrap on the real decode queue, including cached-frame requests.
// Pausing must invalidate that callback without counting an undisplayed loop.
let wrapURL = root.appendingPathComponent("wrap-triple.gif")
try Data([0]).write(to: wrapURL)
let wrapGate = FrameWrapGate()
ImageDocument.observeFrameDurations { observedURL, index in
  if observedURL == wrapURL { wrapGate.observe(index) }
}
var wrapLoopStarts = 0
var lastWrapFrame = -1
viewer.canvas.onZoomChanged = { zoom in
  originalZoomCallback?(zoom)
  if viewer.canvas.image != nil && viewer.frameIndex != lastWrapFrame {
    lastWrapFrame = viewer.frameIndex
    if lastWrapFrame == 0 { wrapLoopStarts += 1 }
  }
}
viewer.open(urls: [wrapURL, url])
waitFor("Loop wrap waits for its asynchronous frame") { wrapGate.isBlocked }
expect(viewer.frameIndex == 2 && wrapLoopStarts == 1,
       "The pending wrap has not displayed a new loop")
expect(!viewer.convertButton.isEnabled && !viewer.editButton.isEnabled &&
       !viewer.previousFrameButton.isEnabled && !viewer.nextFrameButton.isEnabled &&
       viewer.animationButton.isEnabled && viewer.animationButton.title == "暂停动图" &&
       !viewer.previousButton.isEnabled && viewer.nextButton.isEnabled && viewer.pureViewingButton.isEnabled,
       "Pending frame controls prevent editing and navigation while allowing animation pause")
NSApp.sendAction(viewer.animationButton.action!, to: viewer.animationButton.target, from: viewer.animationButton)
expect(!viewer.isAnimating, "Pause cancels a pending loop wrap")
wrapGate.resume()
pump(0.1)
expect(!viewer.isAnimating && viewer.frameIndex == 2 && wrapLoopStarts == 1,
       "A cancelled wrap callback cannot change the paused frame")
expect(viewer.convertButton.isEnabled && viewer.editButton.isEnabled && viewer.previousFrameButton.isEnabled &&
       !viewer.nextFrameButton.isEnabled && viewer.animationButton.title == "播放动图" &&
       !viewer.previousButton.isEnabled && viewer.nextButton.isEnabled && viewer.pureViewingButton.isEnabled,
       "Cancelling a pending frame restores editing and the exact displayed-frame controls")
expect(!wrapGate.didTimeOut, "The controlled decode gate was explicitly released")
NSApp.sendAction(viewer.animationButton.action!, to: viewer.animationButton.target, from: viewer.animationButton)
waitFor("Animation resumes after cancelling a pending wrap") { !viewer.isAnimating && viewer.frameIndex == 2 }
expect(wrapLoopStarts == 3,
       "A cancelled wrap must not consume a finite animation loop")
ImageDocument.observeFrameDurations(nil)
NSApp.sendAction(viewer.animationButton.action!, to: viewer.animationButton.target, from: viewer.animationButton)
waitFor("Completed multi-loop animation can replay") { !viewer.isAnimating && viewer.frameIndex == 2 }
expect(wrapLoopStarts == 6,
       "Explicit replay starts three new loops without counting its initial frame as a wrap")
viewer.canvas.onZoomChanged = originalZoomCallback

viewer.open(urls: [root.appendingPathComponent("slow.png")])
viewer.open(urls: [url, explicit[0]])
waitFor("New image survives stale decode") { viewer.canvas.image != nil && viewer.selectedURL == url }
pump(0.3)
expect(viewer.selectedURL == url && viewer.files.count == 2, "Stale directory callback ignored")
let slowURL = root.appendingPathComponent("slow.png")
let initialStarts = ImageDocument.starts.filter { $0 == slowURL }.count
viewer.open(urls: [slowURL])
waitFor("Slow fixture begins decoding") { ImageDocument.starts.filter { $0 == slowURL }.count > initialStarts }
for _ in 0..<10 { viewer.open(urls: [slowURL]) }
viewer.open(urls: [url, explicit[0]])
waitFor("Latest image bypasses obsolete queued decodes") { viewer.canvas.image != nil && viewer.selectedURL == url }
expect(ImageDocument.starts.filter { $0 == slowURL }.count == initialStarts + 1,
       "Queued obsolete document initializers never run")
let slowAnimation = root.appendingPathComponent("slowfinite.gif")
try Data([0]).write(to: slowAnimation)
viewer.open(urls: [slowAnimation])
viewer.window?.miniaturize(nil)
waitFor("Window minimizes while initial animated decode is pending") { viewer.window?.isMiniaturized == true }
waitFor("Animated image finishes loading while minimized") { viewer.canvas.image != nil }
pump(0.15)
expect(!viewer.isAnimating && viewer.frameIndex == 0, "Background initial decode does not start minimized animation")
viewer.window?.deminiaturize(nil)
waitFor("Restoring minimized image starts its deferred animation") { viewer.isAnimating }
viewer.open(urls: [url, explicit[0]])
waitFor("Static image replaces restored animation") { viewer.canvas.image != nil && viewer.selectedURL == url }
viewer.canvas.onTogglePureViewing?()
expect(viewer.isPureViewing, "Pure viewing is active before direct conversion entry")
viewer.beginConversion(url: url, format: .png, frameIndex: nil)
expect(viewer.isBusy, "Conversion exposes busy state")
expect(!viewer.isPureViewing && !viewer.progressIndicator.isHiddenOrHasHiddenAncestor,
       "Direct conversion entry restores chrome so progress remains visible")
viewer.canvas.onTogglePureViewing?()
expect(!viewer.isPureViewing && !viewer.pureViewingButton.isEnabled &&
       viewingMenu(viewer).items[0].isEnabled == false, "Active conversion prevents pure viewing")
waitFor("Conversion finishes") { !viewer.isBusy }
expect(viewer.statusLabel.stringValue.contains("converted.png"), "Conversion reports output")
expect(viewer.lastOutputURL != nil && !viewer.viewOutputButton.isHidden, "Completed result can be opened")
viewer.beginConversion(url: url, format: .png, frameIndex: nil)
viewer.cancelButton.performClick(nil)
waitFor("Conversion cancellation finishes") { !viewer.isBusy }
expect(viewer.statusLabel.stringValue.contains("已取消"), "Cancellation is distinct from failure")
viewer.beginConversion(url: url, format: .png, frameIndex: nil)
viewer.cancelAndClose()
pump(0.3)
expect(!viewer.isBusy && viewer.canvas.image == nil, "Close cancels task and clears pixels")
expect(viewer.window?.isVisible == false, "Close removes window")
expect(ImageDocument.mainThreadDecodeCount == 0, "No frames decoded on main thread")
let pasteboard = NSPasteboard.withUniqueName()
pasteboard.writeObjects([url as NSURL])
expect(ImageCanvasView.fileURLs(from: pasteboard) == [url], "File drops preserve local URLs")
pasteboard.clearContents()
pasteboard.writeObjects([NSURL(string: "https://example.invalid/image.png")!])
expect(ImageCanvasView.fileURLs(from: pasteboard).isEmpty, "Image drops reject remote URLs")
pasteboard.releaseGlobally()
viewer.canvas.onDropURLs?([url, explicit[0]])
expect(PlayerCore.urls == [url, explicit[0]], "Canvas drops use common app routing without constructing a playback core")
expect(AppDelegate.shared.recentURLs.contains(url), "Successful decode adds image to recent documents")
let recentCount = AppDelegate.shared.recentURLs.count
Preference.recordRecentFiles = false
viewer.open(urls: [url, explicit[0]])
viewer.showWindow(nil)
waitFor("Closed viewer can reopen") { viewer.canvas.image != nil && viewer.window?.isVisible == true }
expect(AppDelegate.shared.recentURLs.count == recentCount, "Disabled history preference is respected")
viewer.convertButton.performClick(nil)
waitFor("Conversion sheet opens before close") { viewer.window?.attachedSheet != nil }
viewer.cancelAndClose()
pump()
expect(viewer.window?.attachedSheet == nil, "Close also dismisses pending conversion confirmation")

let container = root.appendingPathComponent("Container", isDirectory: true)
let child = container.appendingPathComponent("Pictures.gif", isDirectory: true)
let emptyChild = child.appendingPathComponent("Empty", isDirectory: true)
try FileManager.default.createDirectory(at: emptyChild, withIntermediateDirectories: true)
let childImage = child.appendingPathComponent("1.png")
let childAnimation = child.appendingPathComponent("2.gif")
let childVideo = child.appendingPathComponent("3.mp4")
for childFile in [childImage, childAnimation, childVideo] { try Data([0]).write(to: childFile) }
let startsBeforeBrowsing = ImageDocument.starts.count
let browserViewer = ImageViewerWindowController(urls: [], directoryURL: container, defaults: defaults)
func captureBrowser(_ name: String) throws {
  guard let path = ProcessInfo.processInfo.environment["IMAGE_VIEWER_BROWSER_SCREENSHOT_DIR"],
        let window = browserViewer.window, let content = window.contentView else { return }
  window.setContentSize(NSSize(width: 880, height: 620))
  window.makeKeyAndOrderFront(nil)
  content.wantsLayer = true
  content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
  pump(0.1)
  guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
  content.cacheDisplay(in: content.bounds, to: bitmap)
  guard let opaque = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide,
    pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: opaque) else { return }
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  let pixelBounds = NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
  NSColor.windowBackgroundColor.setFill()
  pixelBounds.fill()
  bitmap.draw(in: pixelBounds)
  NSGraphicsContext.restoreGraphicsState()
  if let data = opaque.representation(using: .png, properties: [:]) {
    let output = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name + ".png")
    try data.write(to: output)
    print("Image browser screenshot: \(output.path)")
  }
  let capture = Process()
  capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
  let output = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name + ".window.png")
  capture.arguments = ["-l", String(window.windowNumber), "-o", output.path]
  try capture.run()
  capture.waitUntilExit()
}
browserViewer.showWindow(nil)
browserViewer.window?.makeKeyAndOrderFront(nil)
waitFor("A folder containing only subfolders opens the native browser") {
  !browserViewer.folderBrowser.isLoading && browserViewer.folderBrowser.visibleEntries.count == 1
}
expect(browserViewer.canvas.image == nil && browserViewer.selectedURL == nil &&
       !browserViewer.folderBrowser.isHidden && !browserViewer.slideshowButton.isEnabled,
       "An empty browser starts without a fake image or slideshow")
browserViewer.canvas.onTogglePureViewing?()
expect(!browserViewer.isPureViewing && !browserViewer.pureViewingButton.isEnabled &&
       viewingMenu(browserViewer).items[0].isEnabled == false,
       "An empty folder cannot hide its browser in pure viewing")
expect(browserViewer.folderBrowser.tableView.visibleRect.height > 100,
       "An empty image canvas still gives the folder browser a usable layout")
func activateBrowserEntry(_ url: URL) {
  guard let row = browserViewer.folderBrowser.visibleEntries.firstIndex(where: {
    $0.url.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath()
  }) else { expect(false, "Requested browser entry exists"); return }
  browserViewer.folderBrowser.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
  browserViewer.folderBrowser.openSelectedEntry()
}
activateBrowserEntry(child)
waitFor("Double-clicking a directory enters its direct children") {
  !browserViewer.folderBrowser.isLoading && browserViewer.folderBrowser.visibleEntries.count == 4
}
expect(ImageDocument.starts.count == startsBeforeBrowsing && browserViewer.canvas.image == nil,
       "Even a directory named GIF never reaches the image decoder")
activateBrowserEntry(childImage)
waitFor("Double-clicking a nested image opens it") {
  browserViewer.selectedURL?.lastPathComponent == childImage.lastPathComponent && browserViewer.canvas.image != nil
}
expect(browserViewer.files.map(\.name) == ["1.png", "2.gif"],
       "Nested image navigation excludes folders and video files")
browserViewer.pureViewingButton.performClick(nil)
expect(browserViewer.isPureViewing, "A browser image can enter pure viewing")
browserViewer.open(urls: [], directoryURL: emptyChild)
waitFor("Opening an empty folder restores the browser from pure viewing") {
  !browserViewer.folderBrowser.isLoading && !browserViewer.isPureViewing
}
expect(!browserViewer.sidebarPicker.isHiddenOrHasHiddenAncestor && browserViewer.canvas.image != nil,
       "Opening a folder restores browsing controls while preserving the displayed image")
browserViewer.open(urls: [childImage])
waitFor("The original image folder reopens after leaving pure viewing") {
  !browserViewer.folderBrowser.isLoading && browserViewer.files.count == 2 && browserViewer.canvas.image != nil
}
try captureBrowser("image-folder-minimum")
activateBrowserEntry(childVideo)
expect(PlayerCore.urls.first?.lastPathComponent == childVideo.lastPathComponent &&
       browserViewer.selectedURL?.lastPathComponent == childImage.lastPathComponent,
       "Nested videos use common media routing while retaining the current image")
browserViewer.editButton.performClick(nil)
browserViewer.folderBrowser.goToParent()
activateBrowserEntry(childAnimation)
expect(browserViewer.isEditingImage && browserViewer.selectedURL?.lastPathComponent == childImage.lastPathComponent &&
       browserViewer.folderBrowser.directoryURL?.lastPathComponent == child.lastPathComponent,
       "Folder and file activation respect an active image editing session")
browserViewer.editButton.performClick(nil)
let updateOwner = UUID()
expect(UpdateWorkAdmission.shared.acquire(updateOwner), "Idle image browser can enter the update barrier")
browserViewer.folderBrowser.goToParent()
activateBrowserEntry(childAnimation)
expect(browserViewer.selectedURL?.lastPathComponent == childImage.lastPathComponent &&
       browserViewer.folderBrowser.directoryURL?.lastPathComponent == child.lastPathComponent,
       "Folder and file activation respect the update admission barrier")
UpdateWorkAdmission.shared.release(updateOwner)
activateBrowserEntry(childAnimation)
waitFor("Nested animation begins playing") { browserViewer.isAnimating }
let sequenceBeforeBrowsing = browserViewer.files.map(\.url)
activateBrowserEntry(emptyChild)
waitFor("An empty nested folder remains browsable") { !browserViewer.folderBrowser.isLoading }
expect(browserViewer.isAnimating && browserViewer.files.map(\.url) == sequenceBeforeBrowsing &&
       browserViewer.selectedURL?.lastPathComponent == childAnimation.lastPathComponent,
       "Browsing an empty child folder preserves animation and the image sequence")
browserViewer.folderBrowser.goToParent()
waitFor("Parent navigation restores the containing folder") {
  !browserViewer.folderBrowser.isLoading && browserViewer.folderBrowser.visibleEntries.count == 4
}
browserViewer.folderBrowser.tagFilterControls.filterPopup.selectItem(at: 2)
NSApp.sendAction(browserViewer.folderBrowser.tagFilterControls.filterPopup.action!,
                 to: browserViewer.folderBrowser.tagFilterControls.filterPopup.target,
                 from: browserViewer.folderBrowser.tagFilterControls.filterPopup)
expect(browserViewer.files.map(\.url) == sequenceBeforeBrowsing && browserViewer.isAnimating,
       "Finder tag filtering never replaces the active image sequence or stops animation")
browserViewer.open(urls: [childAnimation, childImage])
waitFor("Explicit nested selection retains its requested order") {
  browserViewer.files.map(\.name) == ["2.gif", "1.png"] && browserViewer.canvas.image != nil
}
expect(browserViewer.sidebarPicker.selectedSegment == 1 && !browserViewer.tableView.isHiddenOrHasHiddenAncestor,
       "Explicit image selection opens its own ordered list")
try captureBrowser("image-selection-minimum")
browserViewer.sidebarPicker.selectedSegment = 0
NSApp.sendAction(browserViewer.sidebarPicker.action!, to: browserViewer.sidebarPicker.target, from: browserViewer.sidebarPicker)
browserViewer.folderBrowser.showDirectory(container, force: true)
waitFor("Explicit selection can explore other folders") { !browserViewer.folderBrowser.isLoading }
expect(browserViewer.files.map(\.name) == ["2.gif", "1.png"] && browserViewer.isAnimating,
       "Switching to folder browsing preserves explicit image order and animation")
waitFor("Explicit image sequence is ready for slideshow") { browserViewer.slideshowButton.isEnabled }
browserViewer.setSlideshowInterval(120)
NSApp.sendAction(browserViewer.slideshowButton.action!, to: browserViewer.slideshowButton.target,
                 from: browserViewer.slideshowButton)
browserViewer.folderBrowser.showDirectory(emptyChild, force: true)
waitFor("A running slideshow can browse an unrelated empty folder") { !browserViewer.folderBrowser.isLoading }
expect(browserViewer.isSlideshowRunning && browserViewer.isAnimating && browserViewer.files.map(\.name) == ["2.gif", "1.png"],
       "Folder navigation preserves both slideshow and animation timers")
browserViewer.open(urls: [childImage])
waitFor("An image folder is ready before a failed refresh") {
  browserViewer.files.count == 2 && browserViewer.slideshowButton.isEnabled && browserViewer.canvas.image != nil
}
let detachedChild = container.appendingPathComponent("Detached", isDirectory: true)
try FileManager.default.moveItem(at: child, to: detachedChild)
browserViewer.folderBrowser.refresh()
waitFor("An unavailable folder reports its load failure") {
  !browserViewer.folderBrowser.isLoading && browserViewer.folderBrowser.loadError != nil
}
expect(browserViewer.files.count == 2 && browserViewer.slideshowButton.isEnabled && browserViewer.canvas.image != nil,
       "A failed browser refresh preserves the image sequence without a stuck loading state")
try FileManager.default.moveItem(at: detachedChild, to: child)
browserViewer.canvas.onTogglePureViewing?()
expect(browserViewer.isPureViewing, "Loaded viewer can enter pure mode before closing")
browserViewer.cancelAndClose()
expect(!browserViewer.folderBrowser.isLoading && browserViewer.canvas.image == nil,
       "Closing the image viewer cancels browser loads as well as image work")
expect(!browserViewer.isPureViewing && !browserViewer.canvas.isPureViewing &&
       browserViewer.window?.styleMask.contains(.fullSizeContentView) == false,
       "Closing pure viewing restores normal window state for later reuse")
browserViewer.open(urls: [], directoryURL: container)
browserViewer.showWindow(nil)
waitFor("A closed image window can reopen directly into a folder") { !browserViewer.folderBrowser.isLoading }
expect(browserViewer.selectedURL == nil && browserViewer.files.isEmpty && browserViewer.canvas.image == nil &&
       browserViewer.window?.representedURL == nil,
       "Reopening an empty folder does not reuse a stale image selection or title")
browserViewer.cancelAndClose()

print("Image viewer UI checks passed: \(checks)")
