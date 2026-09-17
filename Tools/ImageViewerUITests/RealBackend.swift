import Cocoa
import ImageIO

/// Exercise the actual native window with actual ImageIO decoding and conversion.
@main
struct RealImageViewerSmoke {
  static var checks = 0
  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fputs("Real image UI check failed: \(message)\n", stderr); exit(1) }
  }
  static func pump(_ interval: TimeInterval = 0.01) {
    let deadline = Date().addingTimeInterval(interval)
    while Date() < deadline {
      while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
        NSApp.sendEvent(event)
      }
      NSApp.updateWindows()
      RunLoop.main.run(until: Date().addingTimeInterval(0.001))
    }
  }
  static func waitFor(_ message: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(10)
    while !condition() && Date() < deadline { pump() }
    expect(condition(), message)
  }
  static func image(_ color: CGColor) -> CGImage {
    let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
                            bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
    return context.makeImage()!
  }
  static func write(_ url: URL, type: String, images: [CGImage], animation: Bool = false) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, images.count, nil)!
    if animation {
      CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary:
        [kCGImagePropertyGIFLoopCount: 1]] as CFDictionary)
    }
    for (index, image) in images.enumerated() {
      let duration = [0.04, 0.08, 0.06][index % 3]
      let properties: [CFString: Any] = animation ? [kCGImagePropertyGIFDictionary:
        [kCGImagePropertyGIFDelayTime: duration, kCGImagePropertyGIFUnclampedDelayTime: duration]] : [:]
      CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    }
    expect(CGImageDestinationFinalize(destination), "Fixture is encoded")
  }

  static func main() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.finishLaunching()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengying-real-image-ui-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let red = image(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    let green = image(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
    let blue = image(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    let still = root.appendingPathComponent("original.png")
    let gif = root.appendingPathComponent("finite.gif")
    let pages = root.appendingPathComponent("pages.tiff")
    write(still, type: "public.png", images: [red])
    write(gif, type: "com.compuserve.gif", images: [red, green, blue], animation: true)
    write(pages, type: "public.tiff", images: [red, blue])
    let originalBytes = try Data(contentsOf: gif)
    let preferenceDomain = "io.chengying.tests.real-image-ui.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: preferenceDomain)!
    defer { defaults.removePersistentDomain(forName: preferenceDomain) }
    let viewer = ImageViewerWindowController(urls: [still, gif, pages], defaults: defaults)
    viewer.showWindow(nil)
    viewer.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    waitFor("Real PNG displays at full resolution") { viewer.canvas.image?.width == 32 && viewer.convertButton.isEnabled }
    expect(viewer.canvas.image?.height == 24, "Real PNG height is retained")
    expect(viewer.window?.firstResponder === viewer.canvas, "Real image window is keyboard-ready without a mouse click")
    viewer.canvas.actualSize()
    expect(abs(viewer.canvas.imageRect.width * viewer.canvas.backingScale - 32) < 0.001,
           "Real pixels use physical 100 percent scale")
    let stillBytes = try Data(contentsOf: still)
    viewer.editButton.performClick(nil)
    expect(viewer.isEditingImage && viewer.isActiveForUpdate, "Real editor begins a protected session")
    viewer.editingPanel.rotateRightButton.performClick(nil)
    waitFor("Real rotation preview finishes") { !viewer.editPreviewPending }
    expect(viewer.canvas.image?.width == 24 && viewer.canvas.image?.height == 32,
           "Real orientation preview swaps pixel dimensions")
    viewer.canvas.cropSelection = ImagePixelRect(x: 2, y: 3, width: 12, height: 8)
    viewer.editingPanel.widthField.stringValue = "6"
    NSApp.sendAction(viewer.editingPanel.widthField.action!, to: viewer.editingPanel.widthField.target,
                     from: viewer.editingPanel.widthField)
    viewer.convertButton.performClick(nil)
    waitFor("Real editing opens confirmation") { viewer.window?.attachedSheet != nil }
    let editSheet = viewer.window!.attachedSheet!
    viewer.window?.endSheet(editSheet, returnCode: .alertFirstButtonReturn)
    editSheet.orderOut(nil)
    waitFor("Real UI editing exports a file") { !viewer.isBusy && viewer.lastOutputURL != nil }
    let editedOutput = viewer.lastOutputURL!
    let editVerificationQueue = DispatchQueue(label: "io.chengying.tests.image.edit.verify")
    try editVerificationQueue.sync {
      let edited = try ImageDocument(url: editedOutput)
      expect(edited.width == 6 && edited.height == 4, "Real UI passes crop and resize to the full-resolution encoder")
    }
    expect(editedOutput.lastPathComponent.contains("_edited") && editedOutput != still,
           "Real edited output uses a separate sibling filename")
    let afterEditing = try Data(contentsOf: still)
    expect(afterEditing == stillBytes, "Real editing leaves the original PNG untouched")
    expect(viewer.isEditingImage, "A successful export retains the editable preview")
    let retainedSelection = viewer.canvas.cropSelection
    let retainedPlan = try viewer.editingPanel.makePlan(crop: retainedSelection)
    var invalidPlan = retainedPlan
    invalidPlan.outputWidth = Int.max
    viewer.beginConversion(url: still, format: .png, frameIndex: nil, editPlan: invalidPlan)
    waitFor("A real editing error completes without an output") { !viewer.isBusy }
    expect(viewer.lastOutputURL == nil && viewer.statusLabel.stringValue.contains("失败"),
           "Failed editing cannot report a successful file")
    expect(viewer.isEditingImage && viewer.canvas.cropSelection == retainedSelection,
           "An export error retains the editable selection")
    viewer.beginConversion(url: still, format: .png, frameIndex: nil, editPlan: retainedPlan)
    waitFor("Real editing can retry after an export error") { !viewer.isBusy && viewer.lastOutputURL != nil }
    expect(viewer.lastOutputURL != editedOutput && FileManager.default.fileExists(atPath: editedOutput.path),
           "Retry preserves the previously edited output")
    viewer.editButton.performClick(nil)
    expect(viewer.canvas.image?.width == 32 && !viewer.isEditingImage, "Exit restores the real original image")
    viewer.nextButton.performClick(nil)
    waitFor("Real GIF auto-plays") { viewer.isAnimating }
    waitFor("Real finite GIF finishes") { !viewer.isAnimating && viewer.frameIndex == 2 }
    NSApp.sendAction(viewer.animationButton.action!, to: viewer.animationButton.target, from: viewer.animationButton)
    waitFor("Real finished GIF replays from frame zero") { viewer.frameIndex == 0 && viewer.isAnimating }
    NSApp.sendAction(viewer.animationButton.action!, to: viewer.animationButton.target, from: viewer.animationButton)
    let paused = viewer.frameIndex
    pump(0.15)
    expect(!viewer.isAnimating && viewer.frameIndex == paused && viewer.canvas.image != nil,
           "Real GIF pause keeps the displayed frame")
    viewer.animationButton.performClick(nil)
    waitFor("Real replay finishes again") { !viewer.isAnimating && viewer.frameIndex == 2 }

    viewer.beginConversion(url: gif, format: .apng, frameIndex: nil)
    waitFor("Real GIF to APNG conversion completes") { !viewer.isBusy && viewer.lastOutputURL != nil }
    let firstOutput = viewer.lastOutputURL!
    expect(firstOutput != gif && firstOutput.deletingLastPathComponent() == gif.deletingLastPathComponent(),
           "Real conversion produces a separate sibling")
    let verificationQueue = DispatchQueue(label: "io.chengying.tests.image.verify")
    try verificationQueue.sync {
      let converted = try ImageDocument(url: firstOutput)
      expect(converted.isAnimated && converted.frameCount == 3, "Converted APNG retains all actual frames")
      expect(converted.loopCount == 1, "Converted APNG retains finite playback count")
      expect(abs(converted.frameDuration(at: 0) - 0.04) < 0.001 && abs(converted.frameDuration(at: 1) - 0.08) < 0.001,
             "Converted APNG retains nonuniform timing")
    }
    viewer.previousFrameButton.performClick(nil)
    waitFor("Original GIF can still step after converting") { viewer.frameIndex == 1 }
    viewer.animationButton.performClick(nil)
    waitFor("Original GIF can still animate after converting") { viewer.frameIndex == 2 && !viewer.isAnimating }
    viewer.beginConversion(url: gif, format: .apng, frameIndex: nil)
    waitFor("Repeated real conversion completes") { !viewer.isBusy && viewer.lastOutputURL != firstOutput }
    expect(FileManager.default.fileExists(atPath: firstOutput.path), "Repeated export keeps first output")
    let preservedOriginal = try Data(contentsOf: gif)
    expect(preservedOriginal == originalBytes, "Real conversion never changes original file bytes")
    viewer.viewOutputButton.performClick(nil)
    waitFor("Converted result opens in native viewer") { viewer.selectedURL == viewer.lastOutputURL && viewer.canvas.image != nil }
    viewer.open(urls: [pages, still])
    waitFor("Real multi-page TIFF opens") { viewer.selectedURL == pages && viewer.canvas.image != nil && viewer.nextFrameButton.isEnabled }
    viewer.nextFrameButton.performClick(nil)
    waitFor("Real TIFF page navigation decodes the next page") { viewer.frameIndex == 1 }
    viewer.beginConversion(url: pages, format: .png, frameIndex: 1)
    waitFor("Real current TIFF page converts to PNG") { !viewer.isBusy && viewer.lastOutputURL != nil }
    try verificationQueue.sync {
      let result = try ImageDocument(url: viewer.lastOutputURL!)
      expect(result.frameCount == 1 && !result.isAnimated, "Current-page PNG is a single still")
      expect(result.width == 32 && result.height == 24, "Current-page output preserves source dimensions")
    }
    viewer.previousFrameButton.performClick(nil)
    waitFor("TIFF still navigates after current-page conversion") { viewer.frameIndex == 0 }

    // The slideshow must also work with actual ImageIO still, animated, and multi-page files.
    viewer.open(urls: [still, gif, pages])
    waitFor("Real slideshow is ready with all selected files") {
      viewer.slideshowButton.isEnabled && viewer.canvas.image != nil && viewer.selectedURL == still
    }
    viewer.setSlideshowInterval(0.5)
    viewer.loopSlideshowButton.state = .off
    NSApp.sendAction(viewer.slideshowButton.action!, to: viewer.slideshowButton.target, from: viewer.slideshowButton)
    expect(viewer.isSlideshowRunning, "Real slideshow starts")
    waitFor("Real slideshow reaches the animated GIF") { viewer.selectedURL == gif && viewer.isAnimating }
    waitFor("GIF frames do not defer the real slideshow indefinitely") {
      viewer.selectedURL == pages && viewer.canvas.image != nil
    }
    waitFor("Real nonlooping slideshow stops at the last image") { !viewer.isSlideshowRunning }
    expect(viewer.selectedURL == pages && viewer.frameIndex == 0, "Slideshow advances files, not TIFF pages")
    let afterSlideshow = try Data(contentsOf: gif)
    expect(afterSlideshow == originalBytes, "Slideshow does not modify the original animated file")
    viewer.cancelAndClose()
    expect(viewer.window?.isVisible == false && viewer.canvas.image == nil, "Real viewer closes cleanly")
    print("Real image viewer smoke checks passed: \(checks)")
  }
}
