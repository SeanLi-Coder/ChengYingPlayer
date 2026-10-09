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
  static func key(_ viewer: ImageViewerWindowController, code: UInt16, characters: String) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: viewer.window!.windowNumber, context: nil,
                               characters: characters, charactersIgnoringModifiers: characters,
                               isARepeat: false, keyCode: code)!
    viewer.window!.sendEvent(event)
  }
  static func doubleClick(_ viewer: ImageViewerWindowController) {
    let canvas = viewer.canvas
    for (type, count) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 1),
                           (.leftMouseDown, 2), (.leftMouseUp, 2)] {
      let event = NSEvent.mouseEvent(with: type,
        location: canvas.convert(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil),
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: viewer.window!.windowNumber, context: nil, eventNumber: 0,
        clickCount: count, pressure: type == .leftMouseUp ? 0 : 1)!
      viewer.window!.sendEvent(event)
    }
  }
  static func captureWindow(_ viewer: ImageViewerWindowController, name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["IMAGE_PURE_VIEW_SCREENSHOT_DIR"] else { return }
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-l", String(viewer.window!.windowNumber), "-o",
                         URL(fileURLWithPath: path).appendingPathComponent(name + ".png").path]
    try capture.run()
    capture.waitUntilExit()
    expect(capture.terminationStatus == 0, "Only the synthetic image fixture window is captured")
  }
  static func image(_ color: CGColor, width: Int = 32, height: Int = 24) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
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
    key(viewer, code: 48, characters: "\t")
    expect(viewer.isPureViewing && viewer.canvas.isPureViewing,
           "A real decoded image enters pure viewing through the Tab shortcut")
    key(viewer, code: 124, characters: "\u{f703}")
    waitFor("Pure viewing navigates to a real animated GIF") {
      viewer.selectedURL == gif && viewer.canvas.image != nil && viewer.isAnimating
    }
    expect(viewer.isPureViewing && viewer.window?.standardWindowButton(.documentIconButton)?.isHidden != false,
           "Real file navigation preserves pure viewing and hides the updated document icon")
    key(viewer, code: 49, characters: " ")
    let purePausedIndex = viewer.frameIndex
    pump(0.12)
    expect(!viewer.isAnimating && viewer.frameIndex == purePausedIndex && viewer.canvas.image != nil,
           "Space pauses a real animated image while pure-view controls are hidden")
    let animationMenu = viewer.canvas.contextMenuProvider!()
    let resumeAnimation = animationMenu.items.first { $0.action == viewer.animationButton.action }
    expect(resumeAnimation?.isEnabled == true, "Pure-view context menu exposes the real animation playback control")
    NSApp.sendAction(resumeAnimation!.action!, to: resumeAnimation!.target, from: resumeAnimation)
    waitFor("The context menu resumes and completes the real animation in pure viewing") {
      !viewer.isAnimating && viewer.frameIndex == 2
    }
    key(viewer, code: 123, characters: "\u{f702}")
    waitFor("Pure viewing navigates back to the real PNG") { viewer.selectedURL == still && viewer.canvas.image != nil }
    key(viewer, code: 53, characters: "\u{1b}")
    expect(!viewer.isPureViewing && viewer.window?.firstResponder === viewer.canvas,
           "Escape restores normal viewing after real image navigation")
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
    key(viewer, code: 48, characters: "\t")
    key(viewer, code: 1, characters: "s")
    expect(viewer.isSlideshowRunning && viewer.isPureViewing, "Real slideshow starts with the S shortcut in pure viewing")
    waitFor("Real slideshow reaches the animated GIF") { viewer.selectedURL == gif && viewer.isAnimating }
    waitFor("GIF frames do not defer the real slideshow indefinitely") {
      viewer.selectedURL == pages && viewer.canvas.image != nil
    }
    waitFor("Real nonlooping slideshow stops at the last image") { !viewer.isSlideshowRunning }
    expect(viewer.selectedURL == pages && viewer.frameIndex == 0, "Slideshow advances files, not TIFF pages")
    expect(viewer.isPureViewing && viewer.canvas.isPureViewing,
           "A successful slideshow keeps pure viewing enabled on its final image")
    let afterSlideshow = try Data(contentsOf: gif)
    expect(afterSlideshow == originalBytes, "Slideshow does not modify the original animated file")

    let invalid = root.appendingPathComponent("broken.png")
    try Data([0, 1, 2, 3]).write(to: invalid)
    viewer.open(urls: [still, invalid])
    waitFor("Failure fixture starts on a decoded real image") { viewer.selectedURL == still && viewer.canvas.image != nil }
    expect(viewer.isPureViewing, "Opening another image selection preserves an active pure-view session")
    key(viewer, code: 124, characters: "\u{f703}")
    waitFor("A terminal real image decode failure restores normal chrome") {
      viewer.selectedURL == invalid && viewer.canvas.image == nil && !viewer.isPureViewing
    }
    expect(!viewer.statusLabel.isHiddenOrHasHiddenAncestor && !viewer.sidebarPicker.isHiddenOrHasHiddenAncestor &&
           !viewer.pureViewingButton.isEnabled, "The real decode error stays visible with working browser controls")

    // Use real ImageIO files with unrelated aspect ratios, not a fixed-size decode stub.
    let shapes = [(240, 480), (480, 240), (1080, 1066), (600, 840), (16, 2048), (2048, 16), (1, 1), (8, 8)]
    let shapeURLs = shapes.enumerated().map { index, size -> URL in
      let url = root.appendingPathComponent("shape-\(index).png")
      write(url, type: "public.png", images: [image(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1),
                                                  width: size.0, height: size.1)])
      return url
    }
    let shapeBytes = try shapeURLs.map { try Data(contentsOf: $0) }
    let imageWindow = viewer.window!
    imageWindow.setContentSize(NSSize(width: 880, height: 620))
    pump()
    let savedFrame = imageWindow.frame
    let savedMinimum = imageWindow.contentMinSize
    let savedAspect = imageWindow.contentAspectRatio
    let savedAutosave = imageWindow.frameAutosaveName
    viewer.open(urls: shapeURLs)
    waitFor("The portrait geometry fixture loads") { viewer.selectedURL == shapeURLs[0] && viewer.canvas.image != nil }
    viewer.canvas.setZoom(2, anchor: CGPoint(x: 20, y: 30))
    key(viewer, code: 48, characters: "\t")
    for (index, shape) in shapes.enumerated() {
      if index > 0 { key(viewer, code: 124, characters: "\u{f703}") }
      waitFor("A real aspect-ratio fixture is decoded") {
        viewer.selectedURL == shapeURLs[index] && viewer.canvas.image?.width == shape.0 &&
          viewer.canvas.image?.height == shape.1
      }
      pump()
      let rect = viewer.canvas.imageRect
      let bounds = viewer.canvas.bounds
      print("Pure shape \(shape.0)x\(shape.1): frame=\(imageWindow.frame) canvas=\(bounds) image=\(rect)")
      expect(viewer.isPureViewing && viewer.canvas.fitsWindow &&
             abs(rect.minX) < 0.51 && abs(rect.minY) < 0.51 &&
             abs(rect.width - bounds.width) < 0.51 && abs(rect.height - bounds.height) < 0.51,
             "Portrait, landscape, panorama and tiny images fill both pure-view axes")
      expect(abs(rect.width / rect.height - CGFloat(shape.0) / CGFloat(shape.1)) < 0.001,
             "Pure-view window geometry preserves source pixel aspect ratio")
      expect(viewer.canvas.imageOffset == .zero && imageWindow.frameAutosaveName.isEmpty,
             "New pure-view sources keep centered fit without changing normal autosave")
      expect(imageWindow.contentAspectRatio == NSSize(width: shape.0, height: shape.1),
             "Native interactive window resizing uses the current image's aspect ratio")
      let visible = imageWindow.screen!.visibleFrame.insetBy(dx: -1, dy: -1)
      expect(visible.contains(imageWindow.frame), "Extreme aspect ratios remain within the current screen")
      guard let bitmap = viewer.canvas.bitmapImageRepForCachingDisplay(in: bounds) else {
        expect(false, "The synthetic canvas can be rendered to pixels")
        continue
      }
      viewer.canvas.cacheDisplay(in: bounds, to: bitmap)
      // Ignore only the one-pixel antialias boundary of fractional point edges.
      for x in [min(2, bitmap.pixelsWide / 2), bitmap.pixelsWide / 2, max(bitmap.pixelsWide - 3, bitmap.pixelsWide / 2)] {
        for y in [min(2, bitmap.pixelsHigh / 2), bitmap.pixelsHigh / 2, max(bitmap.pixelsHigh - 3, bitmap.pixelsHigh / 2)] {
          let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
          expect(pixel != nil && pixel!.greenComponent > 0.45 && pixel!.blueComponent > 0.65,
                 "Actual pure-view canvas corners, edges and center contain the fixture rather than black bars")
        }
      }
      if index == 0 {
        let originalFrame = imageWindow.frame
        imageWindow.setContentSize(NSSize(width: bounds.width / 2, height: bounds.height / 2))
        pump()
        expect(viewer.canvas.bounds.width < 440 && viewer.canvas.bounds.height < 620,
               "Pure viewing can actually shrink below the editor's former 880x620 minimum")
        expect(abs(viewer.canvas.imageRect.width - viewer.canvas.bounds.width) < 0.001 &&
               abs(viewer.canvas.imageRect.height - viewer.canvas.bounds.height) < 0.001,
               "A window resize immediately refits both canvas axes instead of retaining stale image dimensions")
        imageWindow.setFrame(originalFrame, display: true)
        pump()
      }
      if index == 2 {
        let unmaximized = imageWindow.frame
        doubleClick(viewer)
        pump(0.15)
        print("Pure maximum 1080x1066: frame=\(imageWindow.frame) canvas=\(viewer.canvas.bounds) image=\(viewer.canvas.imageRect) fit=\(viewer.canvas.fitsWindow) screen=\(imageWindow.screen!.visibleFrame)")
        expect(viewer.canvas.fitsWindow && imageWindow.screen!.visibleFrame.insetBy(dx: -1, dy: -1).contains(imageWindow.frame) &&
               abs(viewer.canvas.imageRect.width - viewer.canvas.bounds.width) < 0.51 &&
               abs(viewer.canvas.imageRect.height - viewer.canvas.bounds.height) < 0.51,
               "The 1080x1066 fixture maximizes via actual window event routing without stretching or margins")
        try captureWindow(viewer, name: "pure-1080x1066-maximized")
        doubleClick(viewer)
        pump()
        expect(abs(imageWindow.frame.minX - unmaximized.minX) < 1 &&
               abs(imageWindow.frame.minY - unmaximized.minY) < 1 &&
               abs(imageWindow.frame.width - unmaximized.width) < 1 &&
               abs(imageWindow.frame.height - unmaximized.height) < 1,
               "Double-click restoration preserves the previous near-square pure window")
      }
      if shape.0 <= 8 {
        let fittedZoom = viewer.canvas.zoom
        key(viewer, code: 24, characters: "+")
        expect(viewer.canvas.zoom >= fittedZoom, "Zoom-in never shrinks a tiny image from its larger fitted scale")
        let beforeDecrease = viewer.canvas.zoom
        key(viewer, code: 27, characters: "-")
        expect(abs(viewer.canvas.zoom - beforeDecrease / 1.25) * CGFloat(shape.0) / viewer.canvas.backingScale < 1.1 &&
               viewer.canvas.fitsWindow,
               "Tiny-image zoom-out resizes its fitted window continuously instead of snapping down to 64x")
        key(viewer, code: 53, characters: "\u{1b}")
        expect(viewer.canvas.fitsWindow && viewer.canvas.imageOffset == .zero,
               "Leaving pure view after changing source does not restore another image's manual viewport")
        let beforeNormalZoom = viewer.canvas.zoom
        key(viewer, code: 24, characters: "+")
        expect(viewer.canvas.zoom >= beforeNormalZoom,
               "Ordinary tiny-image zoom-in remains monotonic after a pure-view session")
        let normalZoom = viewer.canvas.zoom
        key(viewer, code: 27, characters: "-")
        expect(abs(viewer.canvas.zoom - normalZoom / 1.25) < 0.001,
               "Manual zoom-out remains continuous after leaving tiny-image pure viewing")
        key(viewer, code: 48, characters: "\t")
        key(viewer, code: 29, characters: "0")
      }
    }

    let variablePages = root.appendingPathComponent("mixed-orientation.tiff")
    write(variablePages, type: "public.tiff", images: [image(CGColor(red: 1, green: 0.3, blue: 0.2, alpha: 1),
                                                           width: 300, height: 600),
                                                       image(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1),
                                                           width: 800, height: 200)])
    viewer.open(urls: [variablePages, shapeURLs[0]])
    waitFor("A real multi-page fixture starts in portrait orientation") {
      viewer.selectedURL == variablePages && viewer.canvas.image?.height == 600
    }
    let portraitRestoreEnvelope = imageWindow.frame
    doubleClick(viewer)
    pump()
    viewer.canvas.setZoom(2, anchor: CGPoint(x: viewer.canvas.bounds.midX + 17, y: viewer.canvas.bounds.midY - 9))
    let pageZoom = viewer.canvas.zoom
    let pageOffset = viewer.canvas.imageOffset
    viewer.nextFrameButton.performClick(nil)
    waitFor("A real TIFF page changes its pixel dimensions") { viewer.frameIndex == 1 && viewer.canvas.image?.width == 800 }
    pump()
    expect(viewer.canvas.zoom == pageZoom && viewer.canvas.imageOffset == pageOffset && !viewer.canvas.fitsWindow,
           "Changing a TIFF page's orientation preserves manual zoom and pan")
    expect(abs(viewer.canvas.bounds.width / viewer.canvas.bounds.height - 4) < 0.001,
           "Multi-page navigation updates the pure-view window to the decoded page's actual aspect")
    doubleClick(viewer)
    pump()
    expect(viewer.canvas.fitsWindow &&
           abs(viewer.canvas.bounds.width / viewer.canvas.bounds.height - 4) < 0.001 &&
           imageWindow.frame.width <= portraitRestoreEnvelope.width + 1 &&
           imageWindow.frame.height <= portraitRestoreEnvelope.height + 1 &&
           imageWindow.screen!.visibleFrame.insetBy(dx: -1, dy: -1).contains(imageWindow.frame),
           "Maximize restoration after a page change fits the new aspect into the old envelope on screen")
    key(viewer, code: 29, characters: "0")
    expect(viewer.canvas.fitsWindow && abs(viewer.canvas.imageRect.minX) < 0.001 &&
           abs(viewer.canvas.imageRect.minY) < 0.001 &&
           abs(viewer.canvas.imageRect.width - viewer.canvas.bounds.width) < 0.001 &&
           abs(viewer.canvas.imageRect.height - viewer.canvas.bounds.height) < 0.001,
           "Fit after a mixed-size page change removes every margin")

    let beforeTransition = imageWindow.frame
    viewer.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: imageWindow))
    viewer.open(urls: [shapeURLs[0], variablePages])
    waitFor("An image may finish decoding during a fullscreen transition") { viewer.canvas.image?.height == 480 }
    expect(imageWindow.frame == beforeTransition, "A fullscreen transition prevents asynchronous decoding from resizing the window")
    viewer.windowDidFailToEnterFullScreen(imageWindow)
    pump()
    expect(abs(viewer.canvas.imageRect.width - viewer.canvas.bounds.width) < 0.001 &&
           abs(viewer.canvas.imageRect.height - viewer.canvas.bounds.height) < 0.001 &&
           imageWindow.contentAspectRatio == NSSize(width: 240, height: 480),
           "Failed fullscreen entry clears transition state and fits the newly decoded image")

    let extremeShapes = [(131_072, 1), (1, 131_072)]
    var extremeURLs: [URL] = []
    for (index, shape) in extremeShapes.enumerated() {
      let url = root.appendingPathComponent("subpoint-\(index).png")
      write(url, type: "public.png", images: [image(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1),
                                                  width: shape.0, height: shape.1)])
      extremeURLs.append(url)
    }
    let extremeBytes = try extremeURLs.map { try Data(contentsOf: $0) }
    for (index, shape) in extremeShapes.enumerated() {
      viewer.open(urls: [extremeURLs[index], shapeURLs[0]])
      waitFor("An extreme real PNG decodes without changing its pixels") {
        viewer.selectedURL == extremeURLs[index] && viewer.canvas.image?.width == shape.0 &&
          viewer.canvas.image?.height == shape.1
      }
      pump()
      expect(viewer.isPureViewing && imageWindow.frame.width >= 64 && imageWindow.frame.height >= 64 &&
             viewer.canvas.bounds.width >= 64 && viewer.canvas.bounds.height >= 64,
             "A subpoint source aspect uses a visible operable viewport instead of a zero-area window")
      expect(imageWindow.contentAspectRatio == .zero,
             "An unrepresentable aspect does not constrain future user drags to a zero-area frame")
      expect(imageWindow.screen!.visibleFrame.insetBy(dx: -1, dy: -1).contains(imageWindow.frame),
             "The extreme-aspect fallback remains on the current screen")
      let rect = viewer.canvas.imageRect
      expect(rect.width > 0 && rect.height > 0 &&
             abs(rect.width / rect.height - CGFloat(shape.0) / CGFloat(shape.1)) < 0.001 &&
             viewer.canvas.bounds.insetBy(dx: -0.001, dy: -0.001).contains(rect),
             "The fallback letterboxes the complete extreme image without cropping or stretching")
      imageWindow.setContentSize(NSSize(width: 1, height: 1))
      pump()
      expect(imageWindow.frame.width >= 64 && imageWindow.frame.height >= 64 &&
             viewer.canvas.bounds.width >= 64 && viewer.canvas.bounds.height >= 64,
             "Actual layout constraints keep a shrinking fallback viewport operable")
      if index == 0 && ProcessInfo.processInfo.environment["IMAGE_VIEWER_TEST_FULLSCREEN"] == "1" {
        var entered = false
        var exited = false
        let enterObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
          object: imageWindow, queue: .main) { _ in entered = true }
        let exitObserver = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
          object: imageWindow, queue: .main) { _ in exited = true }
        imageWindow.toggleFullScreen(nil)
        waitFor("An extreme-aspect fallback can enter native fullscreen") { entered }
        imageWindow.toggleFullScreen(nil)
        waitFor("An extreme-aspect fallback can leave native fullscreen") { exited }
        pump()
        expect(viewer.isPureViewing && imageWindow.contentAspectRatio == .zero &&
               imageWindow.frame.width >= 64 && imageWindow.frame.height >= 64,
               "Native fullscreen exit reinstates the nonzero fallback rather than the source's subpoint aspect")
        NotificationCenter.default.removeObserver(enterObserver)
        NotificationCenter.default.removeObserver(exitObserver)
      }
      key(viewer, code: 53, characters: "\u{1b}")
      pump()
      expect(!viewer.isPureViewing && imageWindow.frame == savedFrame && imageWindow.frameAutosaveName == savedAutosave,
             "Escape exits an extreme-aspect viewport and restores normal geometry and autosave")
      key(viewer, code: 48, characters: "\t")
      expect(viewer.isPureViewing && viewer.canvas.bounds.width >= 64 && viewer.canvas.bounds.height >= 64,
             "Reentering pure viewing preserves the extreme-aspect safety viewport")
    }
    let repeatedExtremePages = root.appendingPathComponent("subpoint-pages.tiff")
    let extremePage = image(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1), width: 131_072, height: 1)
    write(repeatedExtremePages, type: "public.tiff", images: [extremePage, extremePage])
    viewer.open(urls: [repeatedExtremePages, shapeURLs[0]])
    waitFor("A repeated extreme-size TIFF is ready") {
      viewer.selectedURL == repeatedExtremePages && viewer.canvas.image?.width == 131_072 && viewer.nextFrameButton.isEnabled
    }
    imageWindow.setContentSize(NSSize(width: 320, height: 160))
    pump()
    let customFallbackFrame = imageWindow.frame
    viewer.nextFrameButton.performClick(nil)
    waitFor("A same-size extreme TIFF page is displayed") { viewer.frameIndex == 1 }
    pump()
    expect(imageWindow.frame == customFallbackFrame,
           "Same decoded dimensions never reset a user-sized fallback viewport on frame delivery")
    viewer.open(urls: [shapeURLs[0], repeatedExtremePages])
    waitFor("A normal portrait opens after an extreme fallback") { viewer.canvas.image?.height == 480 }
    pump()
    expect(imageWindow.contentAspectRatio == NSSize(width: 240, height: 480) &&
           abs(viewer.canvas.imageRect.width - viewer.canvas.bounds.width) < 0.001 &&
           abs(viewer.canvas.imageRect.height - viewer.canvas.bounds.height) < 0.001,
           "Returning to a representable image restores borderless aspect-locked viewing")
    let viewedExtremeBytes = try extremeURLs.map { try Data(contentsOf: $0) }
    expect(viewedExtremeBytes == extremeBytes, "Extreme image handling preserves every original PNG byte")
    key(viewer, code: 53, characters: "\u{1b}")
    pump()
    expect(imageWindow.frame == savedFrame && imageWindow.contentMinSize == savedMinimum &&
           imageWindow.contentAspectRatio == savedAspect && imageWindow.frameAutosaveName == savedAutosave,
           "Leaving tiny-image pure view restores the full normal editor geometry and autosave")
    let viewedShapeBytes = try shapeURLs.map { try Data(contentsOf: $0) }
    expect(viewedShapeBytes == shapeBytes,
           "Window geometry and viewing never rewrite original image bytes")
    viewer.cancelAndClose()
    expect(viewer.window?.isVisible == false && viewer.canvas.image == nil, "Real viewer closes cleanly")
    print("Real image viewer smoke checks passed: \(checks)")
  }
}
