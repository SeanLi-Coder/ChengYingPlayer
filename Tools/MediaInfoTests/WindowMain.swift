import Cocoa

private final class FakeReader {
  private let condition = NSCondition()
  private var blocked = Set<String>()
  private var released = Set<String>()
  private var failures = Set<String>()
  private var calls: [String: Int] = [:]
  private var tokens: [String: MediaInfoCancellation] = [:]
  private(set) var calledOnMain = false

  func block(_ name: String) {
    condition.lock()
    blocked.insert(name)
    condition.unlock()
  }

  func release(_ name: String) {
    condition.lock()
    released.insert(name)
    condition.broadcast()
    condition.unlock()
  }

  func setFailure(_ name: String, enabled: Bool) {
    condition.lock()
    if enabled { failures.insert(name) } else { failures.remove(name) }
    condition.unlock()
  }

  func token(_ name: String) -> MediaInfoCancellation? {
    condition.lock()
    defer { condition.unlock() }
    return tokens[name]
  }

  func count(_ name: String) -> Int {
    condition.lock()
    defer { condition.unlock() }
    return calls[name, default: 0]
  }

  func read(_ url: URL, _ kind: MediaInfoKind, _ token: MediaInfoCancellation) throws -> MediaInfoSnapshot {
    let name = url.lastPathComponent
    condition.lock()
    calledOnMain = calledOnMain || Thread.isMainThread
    calls[name, default: 0] += 1
    tokens[name] = token
    while blocked.contains(name) && !released.contains(name) {
      // Deliberately ignore cancellation to prove stale completion isolation too.
      condition.wait()
    }
    let shouldFail = failures.contains(name)
    condition.unlock()
    if shouldFail { throw MediaInfoError.readFailed("Fixture metadata could not be read.") }
    let long = name == "long.mp4"
    return MediaInfoSnapshot(url: url, kind: kind, content: MediaInfoContent(sections: [
      MediaInfoSection(id: "file", title: mediaInfoText("section.file", "File"), rows: [
        MediaInfoRow(id: "file.name", label: mediaInfoText("file.name", "Name"), value: name),
        MediaInfoRow(id: "file.path", label: mediaInfoText("file.path", "Location"), value: long ? "/" + String(repeating: "long-path-segment/", count: 100) : url.path),
        MediaInfoRow(id: "file.size", label: mediaInfoText("file.size", "File size"), value: "1.24 GB (" + String(format: mediaInfoText("file.exact_bytes", "%@ bytes"), "1,240,000,000") + ")"),
      ]),
      MediaInfoSection(id: "video", title: kind == .video ? mediaInfoText("video.video_track", "Video track") : mediaInfoText("image.section", "Image"), rows: [
        MediaInfoRow(id: "video.codec", label: mediaInfoText("video.codec", "Codec"), value: "HEVC · Main 10"),
        MediaInfoRow(id: "video.size", label: mediaInfoText("video.dimensions", "Original frame dimensions"), value: "3840 × 2160"),
        MediaInfoRow(id: "video.fps", label: mediaInfoText("video.fps_average", "Average frame rate"), value: "23.976 fps"),
        MediaInfoRow(id: "video.color", label: mediaInfoText("video.hdr_signaling", "Reported HDR signaling"), value: "BT.2020 · PQ · 10 bit"),
        MediaInfoRow(id: "video.unknown", label: mediaInfoText("video.mastering_display", "Mastering display metadata"), value: ""),
      ]),
      MediaInfoSection(id: "audio", title: mediaInfoText("video.audio_track", "Audio track"), rows: [
        MediaInfoRow(id: "audio.codec", label: mediaInfoText("video.codec", "Codec"), value: "AAC LC"),
        MediaInfoRow(id: "audio.layout", label: mediaInfoText("video.channels", "Channels"), value: "2 · 48,000 Hz"),
      ]),
    ], notes: [mediaInfoText("video.note.original", "These values describe the local file, not playback speed, zoom, or preview rotation.")] ))
  }
}

@main
private enum WindowTests {
  private static var checks = 0

  private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
    checks += 1
    print("PASS: \(message)")
  }

  private static func wait(_ message: String, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    check(condition(), message)
  }

  private static func views(in root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap { views(in: $0) }
  }

  private static func url(_ name: String) -> URL {
    URL(fileURLWithPath: "/Media/Local Library/\(name)")
  }

  private static func capture(_ window: NSWindow, requested: NSSize, scale: CGFloat?,
                              name: String, destination: URL) throws -> Data {
    let content = window.contentView!
    let bounds = content.bounds
    let backing = content.convertToBacking(bounds)
    guard let native = content.bitmapImageRepForCachingDisplay(in: bounds) else {
      fatalError("FAIL: AppKit could not allocate the native screenshot bitmap")
    }
    let expected = scale.map { NSSize(width: bounds.width * $0, height: bounds.height * $0) } ?? backing.size
    let width = Int(ceil(expected.width))
    let height = Int(ceil(expected.height))
    let bitmap: NSBitmapImageRep
    if scale != nil {
      // Match AppKit's pixel format while exercising both backing densities on any display.
      guard let explicit = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                           bitsPerSample: native.bitsPerSample, samplesPerPixel: native.samplesPerPixel,
                                           hasAlpha: native.hasAlpha, isPlanar: native.isPlanar,
                                           colorSpaceName: native.colorSpaceName, bitmapFormat: native.bitmapFormat,
                                           bytesPerRow: 0, bitsPerPixel: native.bitsPerPixel) else {
        fatalError("FAIL: AppKit could not allocate the explicit-density screenshot bitmap")
      }
      explicit.size = bounds.size
      bitmap = explicit
    } else {
      bitmap = native
    }
    print("Screenshot \(name): requested=\(NSStringFromSize(requested)) frame=\(NSStringFromRect(window.frame)) " +
          "content=\(NSStringFromRect(bounds)) backing=\(NSStringFromRect(backing)) " +
          "screen=\(window.screen.map { NSStringFromRect($0.visibleFrame) } ?? "none") " +
          "windowScale=\(window.backingScaleFactor) renderScale=\(scale.map(String.init(describing:)) ?? "native") " +
          "bitmapPoints=\(NSStringFromSize(bitmap.size)) pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    check(bitmap.pixelsWide == width && bitmap.pixelsHigh == height,
          "The \(name) bitmap exactly covers the actual content at its rendering density")
    window.effectiveAppearance.performAsCurrentDrawingAppearance {
      content.cacheDisplay(in: bounds, to: bitmap)
    }
    guard let png = bitmap.representation(using: .png, properties: [:]),
          let decoded = NSBitmapImageRep(data: png) else {
      fatalError("FAIL: The \(name) screenshot is not a valid PNG")
    }
    check(decoded.pixelsWide == width && decoded.pixelsHigh == height && png.count > 1024,
          "The \(name) PNG preserves the complete bitmap dimensions")
    var colors = Set<String>()
    for y in stride(from: 0, to: height, by: max(1, height / 32)) {
      for x in stride(from: 0, to: width, by: max(1, width / 32)) {
        if let color = decoded.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9 {
          colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
        }
      }
    }
    check(colors.count > 8, "The \(name) screenshot contains visible, nonuniform interface pixels")
    try png.write(to: destination.appendingPathComponent("\(name).png"))
    return png
  }

  static func main() throws {
    setbuf(stdout, nil)
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let language = CommandLine.arguments[2]
    let expectedTitles = ["en": "Media Information", "zh-Hans": "媒体信息", "zh-Hant": "媒體資訊"]
    check(mediaInfoText("window.title", "Missing localized resource") == expectedTitles[language],
          "The actual application bundle resolves its \(language) localization")
    let fake = FakeReader()
    let inspector = MediaInfoWindowController(reader: fake.read)
    let window = inspector.window!
    let pasteboard = NSPasteboard.withUniqueName()
    defer { inspector.close(); pasteboard.releaseGlobally() }
    check(window.contentMinSize == NSSize(width: 440, height: 360), "The inspector has a usable minimum content size")
    check(!window.canBecomeMain && window.canBecomeKey, "The inspector can select text without becoming the main media owner")
    check(!inspector.copyButton.isEnabled && !inspector.refreshButton.isEnabled, "Initial actions cannot copy stale metadata")
    fake.block("first.mp4")
    inspector.present(url: url("first.mp4"), kind: .video, relativeTo: nil)
    wait("The first background read begins", until: { fake.count("first.mp4") == 1 })
    check(inspector.isLoading && !inspector.copyButton.isEnabled, "Copy is disabled while a read is in flight")
    pasteboard.setString("untouched", forType: .string)
    check(!inspector.copyAll(to: pasteboard) && pasteboard.string(forType: .string) == "untouched", "Loading cannot alter the clipboard")
    inspector.sourceDidChange(url: url("second.mp4"), kind: .video)
    check(fake.token("first.mp4")?.isCancelled == true, "Switching files cancels the old reader token")
    check(fake.count("second.mp4") == 0, "Reads are serialized even when an old reader ignores cancellation")
    fake.release("first.mp4")
    wait("The new file replaces the stale completion", until: { inspector.displayedSnapshot?.url == url("second.mp4") })
    check(window.title == "second.mp4" && !fake.calledOnMain, "The filename is the title and reading never runs on the main thread")
    check(inspector.copyButton.isEnabled && inspector.copyAll(to: pasteboard), "A successful snapshot can be copied")
    check(pasteboard.string(forType: .string) == inspector.displayedSnapshot?.plainText, "Copy All preserves every section and note")

    fake.setFailure("broken.mp4", enabled: true)
    inspector.sourceDidChange(url: url("broken.mp4"), kind: .video)
    wait("Reader errors become a visible failure state", until: { inspector.errorMessage != nil })
    check(inspector.displayedSnapshot == nil && !inspector.copyButton.isEnabled, "Failures cannot retain previous file information")
    let previousClipboard = pasteboard.string(forType: .string)
    check(!inspector.copyAll(to: pasteboard) && pasteboard.string(forType: .string) == previousClipboard, "Errors leave the clipboard unchanged")
    fake.setFailure("broken.mp4", enabled: false)
    inspector.refreshButton.performClick(nil)
    wait("Refresh retries the current source", until: { inspector.displayedSnapshot?.url == url("broken.mp4") })
    check(fake.count("broken.mp4") == 2 && inspector.errorMessage == nil, "A successful retry clears the error")

    fake.block("closing.mp4")
    inspector.sourceDidChange(url: url("closing.mp4"), kind: .video)
    wait("The closing read starts", until: { fake.token("closing.mp4") != nil })
    inspector.close()
    check(fake.token("closing.mp4")?.isCancelled == true && !window.isVisible, "Closing immediately cancels reading and hides the nonmodal window")
    inspector.sourceDidChange(url: url("hidden.jpg"), kind: .image)
    check(fake.count("hidden.jpg") == 0 && inspector.displayedSnapshot == nil, "A hidden inspector clears data without reading a changed source")
    fake.release("closing.mp4")
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    check(inspector.displayedSnapshot == nil && !inspector.copyButton.isEnabled, "An ignored cancellation cannot resurrect a closed window's data")
    inspector.present(url: url("hidden.jpg"), kind: .image, relativeTo: nil)
    wait("The same controller reopens for the current image", until: { inspector.displayedSnapshot?.url == url("hidden.jpg") })
    check(inspector.window === window && window.sheetParent == nil && NSApp.modalWindow == nil, "The owner can retain one independent, nonmodal window")
    inspector.sourceDidChange(url: nil, kind: .image)
    check(inspector.displayedSnapshot == nil && !inspector.refreshButton.isEnabled && !inspector.copyButton.isEnabled,
          "Removing the source clears the inspector and disables file actions")

    inspector.present(url: url("long.mp4"), kind: .video, relativeTo: nil)
    wait("Long metadata is loaded", until: { inspector.displayedSnapshot?.url == url("long.mp4") })
    window.setContentSize(window.contentMinSize)
    window.contentView!.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    window.contentView!.layoutSubtreeIfNeeded()
    let fields = views(in: window.contentView!).compactMap { $0 as? NSTextField }
    let values = fields.filter { $0.identifier?.rawValue.hasPrefix("media-info.") == true }
    check(values.count == 10 && values.allSatisfy { $0.isSelectable && !$0.isEditable }, "Every metadata value supports native selection and copying")
    check(values.first { $0.identifier?.rawValue == "media-info.video.unknown" }?.stringValue == MediaInfoValue.unknown,
          "Empty metadata is explicitly shown as unknown")
    let path = values.first { $0.identifier?.rawValue == "media-info.file.path" }!
    check(path.frame.height > 40 && path.frame.width < 300, "Unbroken long paths wrap vertically instead of forcing a wider window")
    check(!inspector.scrollView.hasHorizontalScroller && inspector.scrollView.documentView!.frame.width <= inspector.scrollView.contentView.bounds.width + 1,
          "Metadata fits the clip width without horizontal overflow")
    check(inspector.scrollView.documentView!.frame.height > inspector.scrollView.contentView.bounds.height,
          "Long metadata remains available in the vertical scroll document")
    inspector.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
    inspector.scrollView.reflectScrolledClipView(inspector.scrollView.contentView)
    check(inspector.scrollView.contentView.bounds.origin.y > 0, "The document can actually scroll at minimum window size")
    for button in [inspector.refreshButton, inspector.copyButton, inspector.closeButton] {
      let rect = button.convert(button.bounds, to: window.contentView)
      check(window.contentView!.bounds.contains(rect), "Footer action remains within the minimum-size window: \(button.title)")
    }

    inspector.present(url: url("Night Flight.mp4"), kind: .video, relativeTo: nil)
    wait("The screenshot snapshot is ready", until: { inspector.displayedSnapshot?.url == url("Night Flight.mp4") })
    let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    for (layout, requested) in [("minimum", window.contentMinSize), ("standard", NSSize(width: 640, height: 660))] {
      window.setContentSize(requested)
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
      window.contentView!.layoutSubtreeIfNeeded()
      let bounds = window.contentView!.bounds
      check(bounds.width >= window.contentMinSize.width && bounds.height >= window.contentMinSize.height,
            "The actual \(layout) content respects the minimum layout size")
      if layout == "minimum" {
        check(bounds.size == requested, "The smaller screenshot exercises the actual minimum-size layout")
      }
      var signatures: [[Data]] = []
      for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        window.appearance = NSAppearance(named: appearance)
        window.contentView!.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let prefix = layout == "standard" ? "media-info-\(name)" : "media-info-minimum-\(name)"
        var rendered: [Data] = []
        for scale: CGFloat? in [nil, 1, 2] {
          let suffix = scale.map { "-\(Int($0))x" } ?? ""
          rendered.append(try capture(window, requested: requested, scale: scale,
                                      name: prefix + suffix, destination: destination))
        }
        signatures.append(rendered)
      }
      for index in 0..<3 {
        check(signatures[0][index] != signatures[1][index],
              "Light and dark \(layout) appearances differ at rendering density \(index)")
      }
    }

    fake.block("native-close.mp4")
    inspector.sourceDidChange(url: url("native-close.mp4"), kind: .video)
    wait("The native close cancellation fixture begins", until: { fake.token("native-close.mp4") != nil })
    window.performClose(nil)
    check(fake.token("native-close.mp4")?.isCancelled == true, "The native titlebar close button also cancels work")
    fake.release("native-close.mp4")
    print("Media information window checks passed: \(checks)")
  }
}
