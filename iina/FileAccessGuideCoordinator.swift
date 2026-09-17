import AppKit

/// Remember that guidance was shown, never pretend to remember a macOS permission grant.
struct FileAccessGuidePolicy {
  static let shownKey = "fileAccessGuideHasBeenShown"
  let defaults: UserDefaults

  func shouldOfferOnLaunch(isInteractive: Bool) -> Bool {
    isInteractive && !defaults.bool(forKey: Self.shownKey)
  }

  func markPresented() { defaults.set(true, forKey: Self.shownKey) }
}

enum FileAccessSettingsLink {
  static func urls(forMajorVersion major: Int) -> [URL] {
    let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    guard major >= 13 else { return [legacy] }
    return [URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!, legacy]
  }

  static func open(majorVersion: Int, opener: (URL) -> Bool) -> Bool {
    for url in urls(forMajorVersion: majorVersion) where opener(url) { return true }
    return false
  }
}

/// All workspace actions are opt-in; merely presenting this guide accesses no media or protected paths.
final class FileAccessGuideCoordinator {
  private let policy: FileAccessGuidePolicy
  private let admission: UpdateWorkAdmission
  private let openSettings: () -> Bool
  private let revealApplication: () -> Void
  private var activity: UUID?
  private var launchOfferPending = false
  private var launchObservers = [NSObjectProtocol]()
  private(set) var windowController: FileAccessGuideWindowController?

  init(defaults: UserDefaults = .standard, admission: UpdateWorkAdmission = .shared,
       openSettings: @escaping () -> Bool = {
         FileAccessSettingsLink.open(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                                     opener: { NSWorkspace.shared.open($0) })
       }, revealApplication: @escaping () -> Void = {
         NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
       }) {
    policy = FileAccessGuidePolicy(defaults: defaults)
    self.admission = admission
    self.openSettings = openSettings
    self.revealApplication = revealApplication
  }

  deinit {
    launchObservers.forEach(NotificationCenter.default.removeObserver)
    if let activity { admission.endActivity(activity) }
  }

  @discardableResult
  func show() -> Bool {
    precondition(Thread.isMainThread)
    if activity == nil {
      guard let token = admission.beginActivity(reason: "busy.unknown") else { return false }
      activity = token
    }
    if windowController == nil {
      let controller = FileAccessGuideWindowController(openSettings: openSettings, revealApplication: revealApplication)
      controller.onClose = { [weak self] in self?.endPresentation() }
      windowController = controller
    }
    policy.markPresented()
    stopLaunchOffer()
    windowController?.present()
    return true
  }

  @discardableResult
  func offerAtLaunch(isInteractive: Bool) -> Bool {
    precondition(Thread.isMainThread)
    guard policy.shouldOfferOnLaunch(isInteractive: isInteractive) else { return false }
    return show()
  }

  /// Defer behind an existing file chooser or inactive app without polling or interrupting it.
  func scheduleLaunchOffer(isInteractive: Bool) {
    precondition(Thread.isMainThread)
    guard policy.shouldOfferOnLaunch(isInteractive: isInteractive), !launchOfferPending else { return }
    launchOfferPending = true
    for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification,
                 NSWindow.didEndSheetNotification] {
      launchObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in self?.queueLaunchOffer()
      })
    }
    queueLaunchOffer()
  }

  func cancelLaunchOffer() {
    precondition(Thread.isMainThread)
    stopLaunchOffer()
  }

  private func queueLaunchOffer() {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.launchOfferPending else { return }
      guard self.policy.shouldOfferOnLaunch(isInteractive: true) else { self.stopLaunchOffer(); return }
      guard NSApp.isActive, NSApp.modalWindow == nil,
            !NSApp.windows.contains(where: { $0.attachedSheet != nil }) else { return }
      self.offerAtLaunch(isInteractive: true)
    }
  }

  private func stopLaunchOffer() {
    launchOfferPending = false
    launchObservers.forEach(NotificationCenter.default.removeObserver)
    launchObservers.removeAll()
  }

  private func endPresentation() {
    if let activity { admission.endActivity(activity) }
    activity = nil
  }
}
