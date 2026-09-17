import Cocoa

/// Simulate activation and modal ownership without activating another real app or showing a chooser.
@objc(FileAccessTestApplication)
private final class FileAccessTestApplication: NSApplication {
  var fixtureIsActive = false
  var fixtureModalWindow: NSWindow?
  var fixtureWindows = [NSWindow]()
  override var isActive: Bool { fixtureIsActive }
  override var modalWindow: NSWindow? { fixtureModalWindow }
  override var windows: [NSWindow] { super.windows + fixtureWindows }
}

private final class FileAccessTestWindow: NSWindow {
  var fixtureSheet: NSWindow?
  override var attachedSheet: NSWindow? { fixtureSheet }
}

@main
@MainActor
private enum FileAccessTests {
  private static var checks = 0

  private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
    checks += 1
    print("PASS: \(message)")
  }

  private static func views(_ root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(views)
  }

  private static func settle(_ window: NSWindow) {
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
  }

  private static func checkLayout(_ controller: FileAccessGuideWindowController, state: String) {
    let window = controller.window!
    settle(window)
    let content = window.contentView!
    let descendants = views(content)
    check(!descendants.contains(where: \.hasAmbiguousLayout), "The \(state) guide has no ambiguous constraints")
    check(content.bounds.width >= 550 && content.bounds.height > 300,
          "The \(state) guide has a usable actual content size")
    for view in descendants where view.identifier?.rawValue.hasPrefix("fileAccess.") == true && !view.isHidden {
      let rectangle = view.convert(view.bounds, to: content)
      check(content.bounds.insetBy(dx: -1, dy: -1).contains(rectangle),
            "The \(state) content contains \(view.identifier!.rawValue)")
      if let label = view as? NSTextField {
        check(label.isSelectable && !label.isEditable, "The \(state) explanation supports safe text selection: \(view.identifier!.rawValue)")
        let needed = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 10_000)).height
        check(label.bounds.height + 1 >= needed, "The \(state) explanation is not vertically clipped: \(view.identifier!.rawValue)")
      }
    }
    let buttonRects = [controller.settingsButton, controller.revealButton, controller.continueButton].map {
      $0.convert($0.bounds, to: content)
    }
    check(!buttonRects[0].intersects(buttonRects[1]) && !buttonRects[0].intersects(buttonRects[2]) &&
          !buttonRects[1].intersects(buttonRects[2]), "The \(state) guide actions do not overlap")
  }

  private static func capture(_ window: NSWindow, scale: CGFloat?, name: String, destination: URL) throws -> Data {
    settle(window)
    let content = window.contentView!
    let bounds = content.bounds
    let backing = content.convertToBacking(bounds)
    guard let native = content.bitmapImageRepForCachingDisplay(in: bounds) else {
      fatalError("FAIL: The guide bitmap cannot be allocated")
    }
    let size = scale.map { NSSize(width: bounds.width * $0, height: bounds.height * $0) } ?? backing.size
    let width = Int(ceil(size.width)), height = Int(ceil(size.height))
    let bitmap: NSBitmapImageRep
    if scale != nil {
      guard let explicit = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                           bitsPerSample: native.bitsPerSample, samplesPerPixel: native.samplesPerPixel,
                                           hasAlpha: native.hasAlpha, isPlanar: native.isPlanar,
                                           colorSpaceName: native.colorSpaceName, bitmapFormat: native.bitmapFormat,
                                           bytesPerRow: 0, bitsPerPixel: native.bitsPerPixel) else {
        fatalError("FAIL: The explicit-density guide bitmap cannot be allocated")
      }
      explicit.size = bounds.size
      bitmap = explicit
    } else { bitmap = native }
    print("Screenshot \(name): frame=\(NSStringFromRect(window.frame)) content=\(NSStringFromRect(bounds)) " +
          "backing=\(NSStringFromRect(backing)) screen=\(window.screen.map { NSStringFromRect($0.visibleFrame) } ?? "none") " +
          "renderScale=\(scale.map(String.init(describing:)) ?? "native") pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    check(bitmap.pixelsWide == width && bitmap.pixelsHigh == height, "The \(name) bitmap covers the actual content bounds")
    window.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: bounds, to: bitmap) }
    guard let png = bitmap.representation(using: .png, properties: [:]), let decoded = NSBitmapImageRep(data: png) else {
      fatalError("FAIL: The guide screenshot is not a decodable PNG")
    }
    check(png.count > 1024 && decoded.pixelsWide == width && decoded.pixelsHigh == height,
          "The \(name) PNG preserves the full content at its rendering density")
    var colors = Set<String>()
    for y in stride(from: 0, to: height, by: max(1, height / 40)) {
      for x in stride(from: 0, to: width, by: max(1, width / 40)) {
        if let color = decoded.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9 {
          colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
        }
      }
    }
    check(colors.count > 8, "The \(name) screenshot contains visible interface content")
    try png.write(to: destination.appendingPathComponent(name + ".png"))
    return png
  }

  private static func checkLinks() {
    let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    let modern = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
    for version in [12, 13, 14, 26] {
      let expected = FileAccessSettingsLink.urls(forMajorVersion: version)
      check(expected == (version >= 13 ? [modern, legacy] : [legacy]),
            "macOS \(version) uses the explicit Full Disk Access destination and correct compatibility order")
      check(!expected.isEmpty && Set(expected).count == expected.count, "macOS \(version) has a unique ordered settings fallback list")
      check(expected.allSatisfy { $0.scheme == "x-apple.systempreferences" }, "macOS \(version) links only to System Settings")
      for successIndex in expected.indices {
        var visited: [URL] = []
        let success = FileAccessSettingsLink.open(majorVersion: version) { url in
          visited.append(url)
          return visited.count - 1 == successIndex
        }
        check(success && visited == Array(expected.prefix(successIndex + 1)),
              "macOS \(version) stops fallback immediately after successful link \(successIndex)")
      }
      var failures: [URL] = []
      check(!FileAccessSettingsLink.open(majorVersion: version) { failures.append($0); return false } && failures == expected,
            "macOS \(version) reports failure only after every settings link fails")
    }
  }

  private static func checkLaunchScheduling(defaults: UserDefaults, application: FileAccessTestApplication) {
    defaults.removeObject(forKey: FileAccessGuidePolicy.shownKey)
    let admission = UpdateWorkAdmission()
    var externalCalls = 0
    func makeCoordinator() -> FileAccessGuideCoordinator {
      FileAccessGuideCoordinator(defaults: defaults, admission: admission,
                                 openSettings: { externalCalls += 1; return true },
                                 revealApplication: { externalCalls += 1 })
    }
    func flush() { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
    func post(_ name: Notification.Name) {
      NotificationCenter.default.post(name: name, object: nil)
      flush()
    }
    let coordinator = makeCoordinator()
    application.fixtureIsActive = false
    coordinator.scheduleLaunchOffer(isInteractive: true)
    coordinator.scheduleLaunchOffer(isInteractive: true)
    flush()
    check(coordinator.windowController == nil && defaults.object(forKey: FileAccessGuidePolicy.shownKey) == nil,
          "Repeated scheduled offers stay pending while the app is inactive without marking presentation")
    let placeholder = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    placeholder.isReleasedWhenClosed = false
    application.fixtureModalWindow = placeholder
    application.fixtureIsActive = true
    post(NSApplication.didBecomeActiveNotification)
    check(coordinator.windowController == nil, "App activation cannot interrupt an existing modal window")
    application.fixtureModalWindow = nil
    let owner = FileAccessTestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    owner.isReleasedWhenClosed = false
    owner.fixtureSheet = placeholder
    application.fixtureWindows = [owner]
    post(NSWindow.didBecomeKeyNotification)
    check(coordinator.windowController == nil, "A key-window notification cannot interrupt an attached file chooser sheet")
    owner.fixtureSheet = nil
    post(NSWindow.didEndSheetNotification)
    check(coordinator.windowController?.window?.isVisible == true && defaults.bool(forKey: FileAccessGuidePolicy.shownKey),
          "Ending the sheet presents the pending guide on the next main-loop turn")
    check(admission.activeReasons == ["busy.unknown"], "Duplicate scheduled offers still create only one active guide lease")
    coordinator.windowController!.window!.performClose(nil)
    post(NSApplication.didBecomeActiveNotification)
    check(coordinator.windowController?.window?.isVisible == false && admission.activeReasons.isEmpty,
          "Observed activation cannot reopen an already-dismissed launch guide")
    application.fixtureWindows = []
    application.fixtureIsActive = false
    placeholder.close()
    owner.close()

    defaults.removeObject(forKey: FileAccessGuidePolicy.shownKey)
    let cancelled = makeCoordinator()
    cancelled.scheduleLaunchOffer(isInteractive: true)
    cancelled.cancelLaunchOffer()
    application.fixtureIsActive = true
    post(NSApplication.didBecomeActiveNotification)
    check(cancelled.windowController == nil && defaults.object(forKey: FileAccessGuidePolicy.shownKey) == nil,
          "Cancelling a queued launch offer prevents both window creation and seen-state persistence")
    let skipped = makeCoordinator()
    skipped.scheduleLaunchOffer(isInteractive: false)
    post(NSWindow.didBecomeKeyNotification)
    check(skipped.windowController == nil, "Noninteractive scheduled launches never register an actionable offer")
    application.fixtureIsActive = false
    var released: FileAccessGuideCoordinator? = makeCoordinator()
    weak var weakReleased = released
    released!.scheduleLaunchOffer(isInteractive: true)
    released = nil
    application.fixtureIsActive = true
    post(NSApplication.didBecomeActiveNotification)
    check(weakReleased == nil && admission.activeReasons.isEmpty && defaults.object(forKey: FileAccessGuidePolicy.shownKey) == nil,
          "Pending notifications and main-queue work do not retain a destroyed coordinator or create a stale guide")

    let blocked = makeCoordinator()
    let installation = UUID()
    check(admission.acquire(installation), "The scheduled-offer barrier fixture acquires installation ownership")
    blocked.scheduleLaunchOffer(isInteractive: true)
    flush()
    check(blocked.windowController == nil && defaults.object(forKey: FileAccessGuidePolicy.shownKey) == nil,
          "A scheduled launch offer also respects the active installation barrier")
    blocked.cancelLaunchOffer()
    admission.release(installation)
    post(NSWindow.didBecomeKeyNotification)
    check(blocked.windowController == nil, "Cancelled scheduled work cannot resurrect after the installation barrier releases")
    check(externalCalls == 0, "Activation, sheets, cancellation, and destruction never invoke external workspace actions")
    application.fixtureIsActive = false
  }

  static func main() throws {
    setbuf(stdout, nil)
    let application = FileAccessTestApplication.shared as! FileAccessTestApplication
    NSApp.setActivationPolicy(.prohibited)
    let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let language = CommandLine.arguments[2]
    let titles = ["en": "File Access Permissions", "zh-Hans": "文件访问权限"]
    check(fileAccessString("menu.title") == titles[language], "The actual test bundle loads \(language) file-access strings")
    check(FileAccessGuidePolicy.shownKey == "fileAccessGuideHasBeenShown", "The persisted key describes presentation, not a permission grant")
    checkLinks()

    let suite = "org.chengying.tests.file-access.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("preserved", forKey: "fixture.unrelated")
    let policy = FileAccessGuidePolicy(defaults: defaults)
    check(!policy.shouldOfferOnLaunch(isInteractive: false), "Noninteractive helper or CLI launches do not offer the guide")
    check(defaults.object(forKey: FileAccessGuidePolicy.shownKey) == nil,
          "Skipping a noninteractive launch does not consume the first interactive offer")
    check(policy.shouldOfferOnLaunch(isInteractive: true), "A fresh interactive launch may offer the guide")
    policy.markPresented()
    defaults.synchronize()
    let reopenedDefaults = UserDefaults(suiteName: suite)!
    check(!FileAccessGuidePolicy(defaults: reopenedDefaults).shouldOfferOnLaunch(isInteractive: true),
          "Reconstructing policy and defaults preserves the once-only decision")
    defaults.removeObject(forKey: FileAccessGuidePolicy.shownKey)

    let admission = UpdateWorkAdmission()
    var settingsCalls = 0, revealCalls = 0
    var settingsSucceeds = false
    var coordinator: FileAccessGuideCoordinator? = FileAccessGuideCoordinator(
      defaults: defaults, admission: admission,
      openSettings: { settingsCalls += 1; return settingsSucceeds },
      revealApplication: { revealCalls += 1 })
    check(settingsCalls == 0 && revealCalls == 0 && coordinator!.windowController == nil,
          "Constructing the coordinator performs no external action or window creation")
    check(!coordinator!.offerAtLaunch(isInteractive: false) && coordinator!.windowController == nil,
          "The coordinator skips helper and CLI launch UI")
    let installation = UUID()
    check(admission.acquire(installation), "The installation barrier can acquire an idle test admission lock")
    check(!coordinator!.show() && !coordinator!.offerAtLaunch(isInteractive: true),
          "Manual and launch presentation both respect the active installation barrier")
    check(defaults.object(forKey: FileAccessGuidePolicy.shownKey) == nil && coordinator!.windowController == nil,
          "A blocked presentation neither marks the guide seen nor creates a window")
    check(settingsCalls == 0 && revealCalls == 0, "Skipped and blocked offers never invoke Settings or Finder")
    admission.release(installation)
    check(coordinator!.offerAtLaunch(isInteractive: true), "The first admitted interactive launch displays the guide")
    let controller = coordinator!.windowController!
    let window = controller.window!
    check(window.isVisible && !window.canBecomeMain && window.canBecomeKey,
          "The guide is visible and selectable without replacing the active media main window")
    check(window.sheetParent == nil && NSApp.modalWindow == nil, "The guide does not block playback with a modal session")
    check(defaults.bool(forKey: FileAccessGuidePolicy.shownKey), "Only successful presentation records that the guide has been shown")
    check(admission.activeReasons == ["busy.unknown"] && !admission.acquire(installation),
          "A visible guide holds an activity lease that vetoes automatic installation")
    check(coordinator!.show() && coordinator!.windowController === controller && admission.activeReasons == ["busy.unknown"],
          "Repeated manual presentation reuses the visible controller and its activity lease")
    check(!coordinator!.offerAtLaunch(isInteractive: true), "An already-shown launch offer does not repeatedly reopen the guide")
    check(settingsCalls == 0 && revealCalls == 0, "Presentation alone never opens System Settings or Finder")

    let labels = views(window.contentView!).compactMap { $0 as? NSTextField }
    for key in ["intro", "limitations", "footer", "step.1.detail", "step.2.detail", "step.3.detail"] {
      check(labels.first { $0.identifier?.rawValue == "fileAccess.\(key)" }?.stringValue == fileAccessString(key),
            "The guide displays the full localized explanation for \(key)")
    }
    check(controller.statusLabel.isHidden && controller.statusLabel.stringValue.isEmpty,
          "The initial guide does not claim a verified or granted permission status")
    check(controller.continueButton.keyEquivalent == "\u{1b}", "Escape remains an explicit way to continue without permission changes")
    checkLayout(controller, state: "initial")
    let initialSize = window.contentView!.bounds.size
    var images: [[Data]] = []
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      window.appearance = NSAppearance(named: appearance)
      var variants: [Data] = []
      for scale: CGFloat? in [nil, 1, 2] {
        let suffix = scale.map { "-\(Int($0))x" } ?? ""
        variants.append(try capture(window, scale: scale, name: "file-access-\(name)\(suffix)", destination: destination))
      }
      images.append(variants)
    }
    for index in 0..<3 {
      check(images[0][index] != images[1][index], "Light and dark guide pixels differ at rendering density \(index)")
    }

    controller.settingsButton.performClick(nil)
    check(settingsCalls == 1 && revealCalls == 0, "Only the explicit Settings button invokes the injected settings action")
    check(!controller.statusLabel.isHidden && controller.statusLabel.stringValue == fileAccessString("settings.failed"),
          "A failed settings link shows the localized manual fallback instructions")
    checkLayout(controller, state: "settings-failure")
    check(window.contentView!.bounds.height > initialSize.height, "The failure explanation reserves actual visible space")
    var failureImages: [Data] = []
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      window.appearance = NSAppearance(named: appearance)
      failureImages.append(try capture(window, scale: nil, name: "file-access-settings-failure-\(name)", destination: destination))
    }
    check(failureImages[0] != failureImages[1], "The visible settings error is rendered in both light and dark appearances")
    settingsSucceeds = true
    controller.settingsButton.performClick(nil)
    check(settingsCalls == 2 && controller.statusLabel.isHidden && controller.statusLabel.stringValue.isEmpty,
          "Opening Settings clears the link error without claiming permission was granted")
    checkLayout(controller, state: "settings-opened")
    check(abs(window.contentView!.bounds.height - initialSize.height) <= 1, "Clearing the link error restores the compact guide size")
    controller.revealButton.performClick(nil)
    check(settingsCalls == 2 && revealCalls == 1 && window.isVisible,
          "Only the explicit reveal button invokes Finder and leaves the guide open")
    check(defaults.persistentDomain(forName: suite)?.count == 2 && defaults.string(forKey: "fixture.unrelated") == "preserved",
          "The guide writes only its presentation marker and preserves unrelated preferences")
    controller.continueButton.performClick(nil)
    check(!window.isVisible && admission.activeReasons.isEmpty, "Continue closes the guide and balances every repeated-presentation lease")
    check(admission.acquire(installation), "Automatic installation becomes admissible immediately after the guide closes")
    admission.release(installation)
    check(!coordinator!.offerAtLaunch(isInteractive: true), "Continuing without access does not cause another launch reminder")
    check(coordinator!.show(), "The user can manually reopen a guide already dismissed at launch")
    coordinator!.windowController!.window!.performClose(nil)
    check(admission.activeReasons.isEmpty, "The native window close button releases the guide activity lease")
    check(coordinator!.show(), "The guide can be reopened for the coordinator deinitialization fixture")
    let retainedWindow = coordinator!.windowController!.window!
    coordinator = nil
    check(admission.activeReasons.isEmpty && admission.acquire(installation), "Coordinator deinitialization cannot leak an update-blocking activity lease")
    admission.release(installation)
    retainedWindow.close()
    check(settingsCalls == 2 && revealCalls == 1, "Closing, reopening, and destruction never invoke external actions")
    checkLaunchScheduling(defaults: defaults, application: application)
    print("File access guide checks passed: \(checks) [\(language)]")
  }
}
