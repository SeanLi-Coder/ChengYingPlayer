import AppKit
import Sparkle

// This disposable app exercises the production user driver and real Sparkle installer.
@MainActor
final class FixtureActivity: UpdateActivityChecking {
  var installationBarrierIsSafe = false
  var didAcquire: (() -> Void)?
  func readiness(completion: @escaping (UpdateReadiness) -> Void) { completion(.ready) }
  func acquireInstallationBarrier(completion: @escaping (UpdateReadiness) -> Void) {
    installationBarrierIsSafe = true
    didAcquire?()
    completion(.ready)
  }
  func releaseInstallationBarrier() { installationBarrierIsSafe = false }
}

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
  let activity = FixtureActivity()
  var driver: AppUpdateUserDriver!
  var updater: SPUUpdater!
  var phaseTimer: Timer?
  var previousPhase = ""
  var receivedAbort = false
  var journal: URL { URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "FixtureJournal") as! String) }

  func record(_ event: String) {
    let line = Data((event + "\n").utf8)
    if !FileManager.default.fileExists(atPath: journal.path) {
      FileManager.default.createFile(atPath: journal.path, contents: nil)
    }
    let handle = try! FileHandle(forWritingTo: journal)
    _ = try! handle.seekToEnd()
    try! handle.write(contentsOf: line)
    try! handle.close()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
    record("launched:\(version):\(ProcessInfo.processInfo.processIdentifier)")
    if version == "2" {
      UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
      record("replacement-relaunched")
      NSApp.terminate(nil)
      return
    }
    activity.didAcquire = { [weak self] in self?.record("gate-acquired") }
    driver = AppUpdateUserDriver(activity: activity, location: { .supported })
    updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
    phaseTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let phase = String(describing: self.driver.phase)
        if self.previousPhase != phase {
          self.previousPhase = phase
          self.record("phase:\(phase)")
          if phase == "failed" {
            self.record("failure:\(self.driver.presentation?.detail ?? "unknown")")
          }
        }
        // Allow Sparkle to deliver its structured error after the driver presents failure.
        if phase == "failed" && self.receivedAbort {
          NSApp.terminate(nil)
        }
      }
    }
    do {
      try updater.start()
      updater.checkForUpdatesInBackground()
    } catch {
      record("failure:\(error)")
      NSApp.terminate(nil)
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if driver?.isInstalling == true {
      record("barrier:\(activity.installationBarrierIsSafe)")
      return activity.installationBarrierIsSafe ? .terminateNow : .terminateCancel
    }
    return .terminateNow
  }

  func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) { record("download-completed") }
  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    record("valid-update:\(item.versionString)")
  }
  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    receivedAbort = true
    let failure = error as NSError
    var cause: NSError? = failure
    // Sparkle wraps archive validation errors in installation errors before forwarding them.
    for _ in 0..<16 {
      guard let current = cause else { break }
      if current.domain == SUSparkleErrorDomain,
         [Int(SUError.signatureError.rawValue), Int(SUError.validationError.rawValue)].contains(current.code) {
        record("signature-rejected:\(current.domain):\(current.code)")
        break
      }
      cause = current.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    record("failure:\(failure.domain):\(failure.code):\(failure.localizedDescription)")
  }
}

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = FixtureDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.accessory)
  app.run()
}
