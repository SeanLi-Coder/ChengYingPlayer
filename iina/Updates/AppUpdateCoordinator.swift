import AppKit
import Sparkle

/// A single updater instance serves startup checks, preferences, and the menu command.
@MainActor
final class AppUpdateCoordinator: NSObject, SPUUpdaterDelegate {
  private let activity: UpdateActivityChecking
  private let defaults: UserDefaults
  private let location: () -> UpdateInstallationLocation
  private let driver: AppUpdateUserDriver
  private var updater: SPUUpdater!
  private var started = false
  private var startupError: Error?
  private var observingBackgroundCheck = false

  init(activity: UpdateActivityChecking, bundle: Bundle = .main, defaults: UserDefaults = .standard) {
    AppUpdatePreferences.migrate(defaults)
    self.activity = activity
    self.defaults = defaults
    let inspectLocation = {
      UpdateInstallationLocation.inspect(bundleURL: bundle.bundleURL)
    }
    location = inspectLocation
    driver = AppUpdateUserDriver(activity: activity, location: inspectLocation)
    super.init()
    updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
    driver.retryCheck = { [weak self] in self?.checkForUpdates(nil) }
    driver.windowController.onAutomaticChecksChanged = { [weak self] enabled in
      self?.automaticallyChecksForUpdates = enabled
    }
  }

  func start() {
    guard !started else { return }
    driver.windowController.setAutomaticallyChecksForUpdates(updater.automaticallyChecksForUpdates)
    guard case .supported = location() else {
      startupError = NSError(domain: "org.chengying.updates", code: 1,
                             userInfo: [NSLocalizedDescriptionKey: AppUpdateText.string("location.move")])
      return
    }
    updater.clearFeedURLFromUserDefaults()
    do {
      try updater.start()
      started = true
      startupError = nil
      if updater.automaticallyChecksForUpdates { updater.checkForUpdatesInBackground() }
    } catch {
      // A startup/offline failure must never stop playback or present a launch-time alert.
      startupError = error
    }
  }

  var automaticallyChecksForUpdates: Bool {
    get { updater.automaticallyChecksForUpdates }
    set {
      defaults.set(true, forKey: AppUpdatePreferences.migrationKey)
      updater.automaticallyChecksForUpdates = newValue
      driver.windowController.setAutomaticallyChecksForUpdates(newValue)
    }
  }

  var isInstalling: Bool { driver.isInstalling }

  @objc func checkForUpdates(_ sender: Any?) {
    if driver.hasActiveSession { driver.focus(); return }
    if !started { start() }
    if let startupError {
      driver.showFailure(detail: startupError.localizedDescription, shouldPresent: true)
    } else if updater.canCheckForUpdates {
      updater.checkForUpdates()
    } else {
      observingBackgroundCheck = true
      driver.showExistingBackgroundCheck()
    }
  }

  /// Call before any applicationShouldTerminate cleanup, not after tasks are cancelled.
  func shouldAllowTerminationForUpdate() -> Bool {
    guard isInstalling else { return true }
    guard activity.installationBarrierIsSafe else {
      driver.deferAfterTerminationVeto()
      return false
    }
    return true
  }

  func allowedChannels(for updater: SPUUpdater) -> Set<String> { [] }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    observingBackgroundCheck = false
  }

  func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
    guard observingBackgroundCheck else { return }
    observingBackgroundCheck = false
    guard driver.phase == .checking || driver.phase == .idle else { return }
    // A menu click during the startup feed request observes that request instead of starting another one.
    let isNoUpdate = error.map {
      ($0 as NSError).domain == SUSparkleErrorDomain && ($0 as NSError).code == Int(SUError.noUpdateError.rawValue)
    } ?? true
    if let error, !isNoUpdate {
      driver.showUpdaterError(error, acknowledgement: {})
    } else {
      let result = error ?? NSError(domain: "org.chengying.updates", code: 0,
                                   userInfo: [NSLocalizedDescriptionKey: AppUpdateText.string("current.detail")])
      driver.showUpdateNotFoundWithError(result, acknowledgement: {})
    }
  }
}
