import AppKit
import Sparkle

private var checks = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}

@MainActor
private final class ActivityFixture: UpdateActivityChecking {
  var status = UpdateReadiness.ready
  var held = false
  var installationBarrierIsSafe: Bool { held && status == .ready }
  var acquired = 0
  var released = 0
  var delayReadiness = false
  var delayAcquire = false
  var onReadiness: ((UpdateReadiness) -> Void)?
  var onAcquire: ((UpdateReadiness) -> Void)?

  func readiness(completion: @escaping (UpdateReadiness) -> Void) {
    if delayReadiness { onReadiness = completion } else { completion(status) }
  }
  func acquireInstallationBarrier(completion: @escaping (UpdateReadiness) -> Void) {
    acquired += 1
    if delayAcquire { onAcquire = completion }
    else { held = status == .ready; completion(status) }
  }
  func releaseInstallationBarrier() { held = false; released += 1 }
}

@MainActor
private final class Scenario {
  let activity = ActivityFixture()
  var instant = Date(timeIntervalSince1970: 10_000)
  var location = UpdateInstallationLocation.supported
  lazy var driver = AppUpdateUserDriver(activity: activity, location: { [unowned self] in self.location },
                                        now: { [unowned self] in self.instant }, usesTimer: false)
  var choices: [SPUUserUpdateChoice] = []
  var protocolDriver: SPUUserDriver { driver }
  func ready() { protocolDriver.showReady(toInstallAndRelaunch: { [unowned self] in self.choices.append($0) }) }
  func advance(_ seconds: TimeInterval) { instant.addTimeInterval(seconds); driver.pollReadiness() }
  func cleanup() { driver.dismissUpdateInstallation() }
}

private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

@MainActor
private func snapshot(_ window: NSWindow, name: String, destination: URL) throws {
  window.orderFront(nil)
  let content = window.contentView!
  content.layoutSubtreeIfNeeded()
  RunLoop.current.run(until: Date().addingTimeInterval(0.05))
  let views = descendants(content).filter { !$0.isHiddenOrHasHiddenAncestor }
  check(!views.contains { $0.hasAmbiguousLayout }, "\(name) has unambiguous native layout")
  for view in views where view is NSTextField || view is NSButton || view is NSProgressIndicator {
    let rect = content.convert(view.bounds, from: view)
    check(content.bounds.insetBy(dx: -1, dy: -1).contains(rect), "\(name) visible control fits the actual window")
  }
  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(content.bounds.width * 2),
                               pixelsHigh: Int(content.bounds.height * 2), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  bitmap.size = content.bounds.size
  content.effectiveAppearance.performAsCurrentDrawingAppearance {
    content.cacheDisplay(in: content.bounds, to: bitmap)
  }
  let data = bitmap.representation(using: .png, properties: [:])!
  check(data.count > 2000, "\(name) screenshot contains rendered content")
  check(bitmap.colorAt(x: 2, y: 2)!.alphaComponent > 0.99, "\(name) screenshot has the real opaque window background")
  if let indicator = views.compactMap({ $0 as? NSProgressIndicator }).first,
     !indicator.isIndeterminate, indicator.doubleValue > 0.3, indicator.doubleValue < 0.7 {
    let rect = content.convert(indicator.bounds, from: indicator)
    let y = bitmap.pixelsHigh - 1 - Int(rect.midY * 2)
    let filled = bitmap.colorAt(x: Int((rect.minX + rect.width * 0.2) * 2), y: y)!.usingColorSpace(.deviceRGB)!
    let empty = bitmap.colorAt(x: Int((rect.minX + rect.width * 0.8) * 2), y: y)!.usingColorSpace(.deviceRGB)!
    let difference = max(abs(filled.redComponent - empty.redComponent),
                         abs(filled.greenComponent - empty.greenComponent),
                         abs(filled.blueComponent - empty.blueComponent))
    check(difference > 0.1, "\(name) visibly renders the completed part of the progress bar")
  }
  try data.write(to: destination.appendingPathComponent("\(name).png"))
}

setbuf(stdout, nil)
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

var progress = UpdateDownloadProgress()
check(progress.fraction == nil, "Unknown content length stays indeterminate")
progress.expected = 200
progress.receive(30)
progress.receive(50)
check(progress.received == 80 && progress.fraction == 0.4, "Download callbacks accumulate deltas")
progress.expected = 50
check(progress.fraction == 0.99, "Incorrect or revised server length never claims completion")
progress.receive(UInt64.max)
check(progress.received == UInt64.max && progress.description.count > 0, "Oversized content counters saturate without overflow")
progress.expected = 0
check(progress.fraction == nil, "A revised unknown length returns to indeterminate")
check(UpdateInstallationLocation.evaluate(path: "/Applications/ChengYing.app", isReadOnly: false) == .supported,
      "Applications supports Sparkle replacement")
check(UpdateInstallationLocation.evaluate(path: "/Users/test/Applications/ChengYing.app", isReadOnly: false) == .supported,
      "Writable user installations do not require hard-coded administrator ownership")
for path in ["/Volumes/ChengYing/ChengYing.app", "/private/var/folders/test/AppTranslocation/token/d/ChengYing.app"] {
  check(UpdateInstallationLocation.evaluate(path: path, isReadOnly: false) == .moveToApplications,
        "DMG and translocated installations fail safely")
}
check(UpdateInstallationLocation.evaluate(path: "/Applications/ChengYing.app", isReadOnly: true) == .moveToApplications,
      "Read-only installation refuses automatic replacement")

let suite = "org.chengying.tests.updates.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defaults.set(false, forKey: AppUpdatePreferences.automaticChecksKey)
AppUpdatePreferences.migrate(defaults)
check(defaults.bool(forKey: AppUpdatePreferences.automaticChecksKey), "Legacy disabled default migrates once")
defaults.set(false, forKey: AppUpdatePreferences.automaticChecksKey)
AppUpdatePreferences.migrate(defaults)
check(!defaults.bool(forKey: AppUpdatePreferences.automaticChecksKey), "Subsequent user opt-out is preserved")
defaults.removePersistentDomain(forName: suite)
defaults.setVolatileDomain([AppUpdatePreferences.automaticChecksKey: false], forName: UserDefaults.argumentDomain)
AppUpdatePreferences.migrate(defaults)
check(!defaults.bool(forKey: AppUpdatePreferences.automaticChecksKey) && !defaults.bool(forKey: AppUpdatePreferences.migrationKey),
      "Command-line disable is honored and does not consume the migration")
defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
defaults.removePersistentDomain(forName: suite)

MainActor.assumeIsolated {
  let routing = Scenario()
  check(!routing.driver.windowController.window!.canBecomeMain,
        "The update window never replaces the active player's main window")
  check(routing.driver.windowController.window!.canBecomeKey,
        "The update window still accepts keyboard focus for its own controls")
  routing.cleanup()

  let cancelledManual = Scenario()
  cancelledManual.protocolDriver.showUserInitiatedUpdateCheck(cancellation: {})
  check(cancelledManual.driver.isUserInitiatedSession,
        "A manual update check requests foreground presentation")
  cancelledManual.driver.cancelCurrent()
  cancelledManual.driver.handleOffer(informationOnly: false, alreadyInstalling: false) { _ in }
  check(!cancelledManual.driver.isUserInitiatedSession,
        "An automatic offer after a cancelled manual check does not inherit foreground activation")
  cancelledManual.cleanup()

  let dismissedManual = Scenario()
  dismissedManual.protocolDriver.showUserInitiatedUpdateCheck(cancellation: {})
  dismissedManual.protocolDriver.dismissUpdateInstallation()
  check(!dismissedManual.driver.isUserInitiatedSession,
        "Final Sparkle dismissal clears manual presentation state")
  dismissedManual.protocolDriver.showUserInitiatedUpdateCheck(cancellation: {})
  dismissedManual.protocolDriver.showUpdateInstalledAndRelaunched(false, acknowledgement: {})
  check(!dismissedManual.driver.isUserInitiatedSession,
        "A completed non-relaunching installation clears manual presentation state")
  dismissedManual.cleanup()

  let automatic = Scenario()
  automatic.driver.handleOffer(informationOnly: false, alreadyInstalling: false) { automatic.choices.append($0) }
  check(automatic.choices == [.install] && automatic.driver.phase == .downloading,
        "A discovered regular release immediately starts the visible download flow")
  automatic.cleanup()

  let download = Scenario()
  var cancelled = 0
  download.protocolDriver.showDownloadInitiated(cancellation: { cancelled += 1 })
  download.protocolDriver.showDownloadDidReceiveExpectedContentLength(100)
  download.protocolDriver.showDownloadDidReceiveData(ofLength: 25)
  download.protocolDriver.showDownloadDidReceiveData(ofLength: 25)
  check(download.driver.presentation?.progress == 0.5, "Real Sparkle protocol callbacks update visible progress")
  check(download.driver.presentation?.detail.contains("50%") == true, "Visible download text includes a percentage as well as byte counts")
  let toggle = descendants(download.driver.windowController.window!.contentView!).compactMap { $0 as? NSButton }
    .first { $0.title == AppUpdateText.string("preference.automatic") }!
  var automaticChanges: [Bool] = []
  download.driver.windowController.onAutomaticChecksChanged = { automaticChanges.append($0) }
  download.driver.windowController.setAutomaticallyChecksForUpdates(true)
  toggle.performClick(nil)
  check(automaticChanges == [false] && toggle.state == .off, "The native automatic-update checkbox reports user opt-out")
  download.driver.windowController.setAutomaticallyChecksForUpdates(true)
  check(toggle.state == .on && automaticChanges == [false], "Programmatic checkbox refresh does not overwrite stored preferences")
  download.driver.windowController.window?.performClose(nil)
  check(cancelled == 0 && download.driver.phase == .downloading && download.driver.windowController.window?.isVisible == false,
        "Closing progress window hides it without cancelling the download")
  download.protocolDriver.showUpdateInFocus?()
  check(download.driver.windowController.window?.isVisible == true, "Manual check can focus the same existing update session")
  download.driver.cancelCurrent()
  check(cancelled == 1 && download.driver.phase == .idle, "Explicit cancellation invokes the download cancellation exactly once")
  download.driver.cancelCurrent()
  check(cancelled == 1, "Repeated cancellation is harmless")

  let busy = Scenario()
  busy.activity.status = .busy(["busy.playback", "busy.videoTask"])
  busy.ready()
  busy.advance(100)
  check(busy.choices.isEmpty && busy.activity.acquired == 0, "Active playback and export are never interrupted")
  busy.activity.status = .ready
  busy.advance(0)
  busy.advance(9)
  check(busy.choices.isEmpty, "Idle transition starts a full ten-second countdown")
  busy.activity.status = .busy(["busy.images"])
  busy.advance(1)
  busy.activity.status = .ready
  busy.advance(1)
  busy.advance(9)
  check(busy.choices.isEmpty, "New activity resets the entire countdown")
  busy.advance(1)
  check(busy.choices == [.install] && busy.activity.installationBarrierIsSafe && busy.driver.isInstalling,
        "Installation is requested only after the final atomic barrier is acquired")
  busy.cleanup()
  check(!busy.activity.held, "Ending the update session releases its barrier")

  let resumed = Scenario()
  resumed.activity.status = .busy(["busy.downloads"])
  resumed.driver.handleOffer(informationOnly: false, alreadyInstalling: true) { resumed.choices.append($0) }
  resumed.advance(100)
  check(resumed.choices.isEmpty, "A resumed already-installing update cannot bypass activity protection")
  resumed.driver.cancelCurrent()
  check(resumed.choices == [.skip], "Resumed update uses explicit Skip this version semantics")

  let later = Scenario()
  later.ready()
  later.driver.toggleDeferral()
  later.advance(120)
  check(later.choices.isEmpty && later.driver.phase == .waiting, "Later pauses restart without cancelling or interrupting tasks")
  later.driver.toggleDeferral()
  later.advance(9)
  check(later.choices.isEmpty, "Resuming again gives the user ten seconds")
  later.advance(1)
  check(later.choices == [.install], "Explicit resume restores automatic installation")
  later.cleanup()

  let race = Scenario()
  race.activity.delayAcquire = true
  race.ready()
  race.advance(10)
  check(race.activity.acquired == 1, "Final barrier request is outstanding")
  race.driver.toggleDeferral()
  race.driver.toggleDeferral()
  race.advance(100)
  check(race.activity.acquired == 1, "A second acquisition cannot overtake an outstanding stale request")
  race.activity.held = true
  race.activity.onAcquire?(.ready)
  check(race.choices.isEmpty && !race.activity.held, "A stale successful barrier is released without triggering installation")
  race.cleanup()

  let stale = Scenario()
  stale.activity.delayReadiness = true
  stale.ready()
  stale.driver.cancelCurrent()
  stale.activity.onReadiness?(.ready)
  stale.advance(100)
  check(stale.choices == [.skip] && stale.activity.acquired == 0, "Cancelled sessions ignore late asynchronous readiness replies")

  let barrierBusy = Scenario()
  barrierBusy.activity.delayAcquire = true
  barrierBusy.ready()
  barrierBusy.advance(10)
  barrierBusy.activity.status = .busy(["busy.subtitles"])
  barrierBusy.activity.onAcquire?(.busy(["busy.subtitles"]))
  check(barrierBusy.choices.isEmpty && !barrierBusy.activity.held, "Activity beginning during final acquisition aborts restart safely")
  barrierBusy.cleanup()

  let badLocation = Scenario()
  badLocation.location = .moveToApplications
  badLocation.driver.handleOffer(informationOnly: false, alreadyInstalling: false) { badLocation.choices.append($0) }
  check(badLocation.choices == [.dismiss] && badLocation.driver.phase == .failed,
        "Read-only location is explained before downloading or replacing anything")
  badLocation.cleanup()
  let informational = Scenario()
  informational.driver.handleOffer(informationOnly: true, alreadyInstalling: false) { informational.choices.append($0) }
  check(informational.choices == [.dismiss], "Informational releases are never downloaded")
  informational.cleanup()

  let veto = Scenario()
  veto.ready()
  veto.advance(10)
  veto.driver.deferAfterTerminationVeto()
  var retries = 0
  veto.protocolDriver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: { retries += 1 })
  check(!veto.activity.held && !veto.driver.isInstalling && veto.driver.phase == .waiting,
        "A termination veto releases the barrier and returns to waiting")
  veto.advance(10)
  check(retries == 1 && veto.activity.held, "Sparkle termination retry is gated by a fresh countdown and barrier")
  veto.cleanup()

  let offline = Scenario()
  var acknowledgements = 0
  let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
  offline.protocolDriver.showUpdaterError(failure, acknowledgement: { acknowledgements += 1 })
  check(acknowledgements == 1 && offline.driver.windowController.window?.isVisible == false,
        "Offline background checks do not interrupt startup with an error window")
  offline.protocolDriver.showUserInitiatedUpdateCheck(cancellation: {})
  offline.protocolDriver.showUpdaterError(failure, acknowledgement: { acknowledgements += 1 })
  offline.protocolDriver.dismissUpdateInstallation()
  check(offline.driver.windowController.window?.isVisible == true && offline.driver.phase == .failed,
        "Manual failures remain visible after Sparkle dismisses the session")
  var retried = 0
  offline.driver.retryCheck = { retried += 1 }
  offline.driver.windowController.onPrimary?()
  check(retried == 1, "The retained error action can retry the same coordinator")
  offline.driver.windowController.window?.orderOut(nil)

  let current = Scenario()
  current.protocolDriver.showUpdateNotFoundWithError(failure, acknowledgement: {})
  check(current.driver.windowController.window?.isVisible == false, "No-update background result stays silent")
  current.protocolDriver.showUserInitiatedUpdateCheck(cancellation: {})
  current.protocolDriver.showUpdateNotFoundWithError(failure, acknowledgement: {})
  check(current.driver.windowController.window?.isVisible == true, "Manual no-update result stays visible")
  current.driver.windowController.window?.orderOut(nil)

  let observed = Scenario()
  observed.driver.showExistingBackgroundCheck()
  check(observed.driver.phase == .checking && observed.driver.windowController.window?.isVisible == true,
        "A menu click can observe an in-flight startup request without starting another session")
  observed.protocolDriver.showUpdateNotFoundWithError(failure, acknowledgement: {})
  check(observed.driver.phase == .finished && observed.driver.windowController.window?.isVisible == true,
        "An observed background request produces a visible manual result")
  observed.driver.windowController.window?.orderOut(nil)

  let visuals = Scenario()
  visuals.driver.windowController.setAutomaticallyChecksForUpdates(true)
  visuals.protocolDriver.showDownloadInitiated(cancellation: {})
  visuals.protocolDriver.showDownloadDidReceiveExpectedContentLength(100_000_000)
  visuals.protocolDriver.showDownloadDidReceiveData(ofLength: 42_000_000)
  let actualProgress = descendants(visuals.driver.windowController.window!.contentView!).compactMap { $0 as? NSProgressIndicator }.first!
  check(actualProgress.doubleValue == 0.42 && !actualProgress.isIndeterminate && actualProgress.maxValue == 1,
        "The native indicator receives the download fraction without animation resetting it")
  visuals.driver.windowController.window?.appearance = NSAppearance(named: .aqua)
  try! snapshot(visuals.driver.windowController.window!, name: "update-download-light", destination: destination)
  visuals.protocolDriver.showDownloadDidStartExtractingUpdate()
  visuals.protocolDriver.showExtractionReceivedProgress(.nan)
  check(visuals.driver.presentation?.progress == nil, "Invalid extraction progress stays indeterminate")
  visuals.protocolDriver.showExtractionReceivedProgress(1.5)
  check(visuals.driver.presentation?.progress == 1, "Extraction progress is safely clamped")
  visuals.activity.status = .busy(["busy.playback", "busy.downloads"])
  visuals.ready()
  visuals.driver.windowController.window?.appearance = NSAppearance(named: .darkAqua)
  try! snapshot(visuals.driver.windowController.window!, name: "update-waiting-dark", destination: destination)
  visuals.activity.status = .ready
  visuals.advance(0)
  try! snapshot(visuals.driver.windowController.window!, name: "update-countdown-dark", destination: destination)
  visuals.cleanup()

  for language in ["en", "zh-Hans", "zh-Hant"] {
    let bundle = Bundle(path: Bundle.main.path(forResource: language, ofType: "lproj")!)!
    for key in ["window.title", "waiting.countdown", "busy.playback", "busy.unknown", "location.move", "action.skip_version"] {
      check(bundle.localizedString(forKey: key, value: nil, table: "Updates") != key,
            "\(language) resolves required update text \(key)")
    }
    let table = try! Data(contentsOf: URL(fileURLWithPath: bundle.path(forResource: "Updates", ofType: "strings")!))
    let strings = try! PropertyListSerialization.propertyList(from: table, format: nil) as! [String: String]
    let baseData = try! Data(contentsOf: Bundle.main.url(forResource: "Updates", withExtension: "strings", subdirectory: nil,
                                                        localization: "en")!)
    let base = try! PropertyListSerialization.propertyList(from: baseData, format: nil) as! [String: String]
    check(Set(strings.keys) == Set(base.keys), "\(language) contains every update localization key")
  }
}
print("App update tests passed: \(checks) checks")
