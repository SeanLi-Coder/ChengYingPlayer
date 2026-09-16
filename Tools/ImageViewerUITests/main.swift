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
let viewer = ImageViewerWindowController(urls: [url])
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

print("Image viewer UI checks passed: \(checks)")
