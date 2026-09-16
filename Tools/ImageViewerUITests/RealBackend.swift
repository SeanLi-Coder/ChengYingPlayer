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
    let viewer = ImageViewerWindowController(urls: [still, gif, pages])
    viewer.showWindow(nil)
    viewer.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    waitFor("Real PNG displays at full resolution") { viewer.canvas.image?.width == 32 && viewer.convertButton.isEnabled }
    expect(viewer.canvas.image?.height == 24, "Real PNG height is retained")
    expect(viewer.window?.firstResponder === viewer.canvas, "Real image window is keyboard-ready without a mouse click")
    viewer.canvas.actualSize()
    expect(abs(viewer.canvas.imageRect.width * viewer.canvas.backingScale - 32) < 0.001,
           "Real pixels use physical 100 percent scale")
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
    viewer.cancelAndClose()
    expect(viewer.window?.isVisible == false && viewer.canvas.image == nil, "Real viewer closes cleanly")
    print("Real image viewer smoke checks passed: \(checks)")
  }
}
