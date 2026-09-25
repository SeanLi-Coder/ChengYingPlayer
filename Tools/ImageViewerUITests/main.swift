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
viewer.window?.setFrame(frame, display: true)

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
NSApp.sendAction(viewer.animationButton.action!, to: viewer.animationButton.target, from: viewer.animationButton)
expect(!viewer.isAnimating, "Pause cancels a pending loop wrap")
wrapGate.resume()
pump(0.1)
expect(!viewer.isAnimating && viewer.frameIndex == 2 && wrapLoopStarts == 1,
       "A cancelled wrap callback cannot change the paused frame")
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
viewer.beginConversion(url: url, format: .png, frameIndex: nil)
expect(viewer.isBusy, "Conversion exposes busy state")
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
browserViewer.cancelAndClose()
expect(!browserViewer.folderBrowser.isLoading && browserViewer.canvas.image == nil,
       "Closing the image viewer cancels browser loads as well as image work")
browserViewer.open(urls: [], directoryURL: container)
browserViewer.showWindow(nil)
waitFor("A closed image window can reopen directly into a folder") { !browserViewer.folderBrowser.isLoading }
expect(browserViewer.selectedURL == nil && browserViewer.files.isEmpty && browserViewer.canvas.image == nil &&
       browserViewer.window?.representedURL == nil,
       "Reopening an empty folder does not reuse a stale image selection or title")
browserViewer.cancelAndClose()

print("Image viewer UI checks passed: \(checks)")
