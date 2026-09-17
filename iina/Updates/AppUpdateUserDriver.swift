import AppKit
import Sparkle

/// Sparkle owns verification and replacement; this driver owns only presentation and consent timing.
@MainActor
final class AppUpdateUserDriver: NSObject, SPUUserDriver {
  enum Phase { case idle, checking, downloading, extracting, waiting, installing, finished, failed }

  private let activity: UpdateActivityChecking
  private let location: () -> UpdateInstallationLocation
  private let now: () -> Date
  private let usesTimer: Bool
  private var timer: Timer?
  private var generation = 0
  private var checkingReadiness = false
  private var acquiringBarrier = false
  private var idleSince: Date?
  private var deferredByUser = false
  private var pendingInstall: (() -> Void)?
  private var pendingCancel: (() -> Void)?
  private var cancellation: (() -> Void)?
  private var retryTermination: (() -> Void)?
  private var terminationWasVetoed = false
  private var cancelTitleKey = "action.cancel"
  private var manual = false
  private var offeredVersion = ""
  private var download = UpdateDownloadProgress()
  private(set) var phase: Phase = .idle
  private(set) var isInstalling = false
  private(set) var presentation: AppUpdatePresentation?
  let windowController: AppUpdateWindowController
  var retryCheck: (() -> Void)?

  var isUserInitiatedSession: Bool { manual }

  var hasActiveSession: Bool {
    switch phase {
    case .checking, .downloading, .extracting, .waiting, .installing: return true
    default: return false
    }
  }

  init(activity: UpdateActivityChecking,
       location: @escaping () -> UpdateInstallationLocation,
       now: @escaping () -> Date = { Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime) },
       usesTimer: Bool = true) {
    self.activity = activity
    self.location = location
    self.now = now
    self.usesTimer = usesTimer
    windowController = AppUpdateWindowController()
    super.init()
  }

  private func show(_ value: AppUpdatePresentation, present: Bool = false) {
    presentation = value
    windowController.render(value)
    if present { windowController.present(activate: isUserInitiatedSession) }
  }

  func focus() { windowController.present(activate: true) }

  func showExistingBackgroundCheck() {
    manual = true
    phase = .checking
    windowController.onPrimary = nil
    windowController.onSecondary = { [weak self] in self?.windowController.window?.orderOut(nil) }
    show(AppUpdatePresentation(title: AppUpdateText.string("checking.title"),
                               detail: AppUpdateText.string("checking.detail"), progress: nil,
                               secondaryTitle: AppUpdateText.string("action.close")), present: true)
  }

  private func clearWork() {
    generation += 1
    timer?.invalidate()
    timer = nil
    checkingReadiness = false
    idleSince = nil
    pendingInstall = nil
    pendingCancel = nil
    cancellation = nil
    retryTermination = nil
    terminationWasVetoed = false
    deferredByUser = false
    isInstalling = false
    activity.releaseInstallationBarrier()
    windowController.onPrimary = nil
    windowController.onSecondary = nil
  }

  func show(_ request: SPUUpdatePermissionRequest,
            reply: @escaping (SUUpdatePermissionResponse) -> Void) {
    // The app has an explicit, reversible automatic-update preference.
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: true,
                                    automaticUpdateDownloading: false, sendSystemProfile: false))
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    clearWork()
    manual = true
    phase = .checking
    self.cancellation = cancellation
    windowController.onPrimary = { [weak self] in self?.cancelCurrent() }
    show(AppUpdatePresentation(title: AppUpdateText.string("checking.title"),
                               detail: AppUpdateText.string("checking.detail"), progress: nil,
                               primaryTitle: AppUpdateText.string("action.cancel")), present: true)
  }

  func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                       reply: @escaping (SPUUserUpdateChoice) -> Void) {
    manual = manual || state.userInitiated
    offeredVersion = appcastItem.displayVersionString
    handleOffer(informationOnly: appcastItem.isInformationOnlyUpdate,
                alreadyInstalling: state.stage == .installing, reply: reply)
  }

  // The shared offer path is exercised without constructing Sparkle's private state initializer.
  func handleOffer(informationOnly: Bool, alreadyInstalling: Bool,
                   reply: @escaping (SPUUserUpdateChoice) -> Void) {
    cancellation = nil
    guard !informationOnly else {
      showFailure(detail: AppUpdateText.string("information_only"), shouldPresent: true)
      reply(.dismiss)
      return
    }
    guard case .supported = location() else {
      showFailure(detail: AppUpdateText.string("location.move"), shouldPresent: true)
      reply(.dismiss)
      return
    }
    if alreadyInstalling {
      // This reply can relaunch immediately, so resumed updates need the same barrier.
      waitForInstallation(install: { reply(.install) }, cancel: { reply(.skip) },
                          cancelTitle: "action.skip_version")
    } else {
      phase = .downloading
      show(AppUpdatePresentation(title: AppUpdateText.string("download.title"),
                                 detail: AppUpdateText.format("download.version", offeredVersion),
                                 progress: nil), present: true)
      reply(.install)
    }
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    let shouldPresent = manual
    clearWork()
    phase = .finished
    if shouldPresent {
      show(AppUpdatePresentation(title: AppUpdateText.string("current.title"),
                                 detail: error.localizedDescription, progress: nil, isWorking: false,
                                 primaryTitle: AppUpdateText.string("action.close")), present: true)
      windowController.onPrimary = { [weak self] in self?.windowController.window?.orderOut(nil) }
    }
    acknowledgement()
    manual = false
  }

  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    showFailure(detail: error.localizedDescription, shouldPresent: manual || hasActiveSession)
    acknowledgement()
  }

  func showFailure(detail: String, shouldPresent: Bool) {
    clearWork()
    phase = .failed
    if shouldPresent {
      show(AppUpdatePresentation(title: AppUpdateText.string("error.title"),
                                 detail: AppUpdateText.format("error.detail", detail),
                                 progress: nil, isWorking: false,
                                 primaryTitle: AppUpdateText.string("action.retry"),
                                 secondaryTitle: AppUpdateText.string("action.close")), present: true)
      windowController.onPrimary = { [weak self] in self?.retryCheck?() }
      windowController.onSecondary = { [weak self] in self?.windowController.window?.orderOut(nil) }
    }
    manual = false
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    phase = .downloading
    download = UpdateDownloadProgress()
    self.cancellation = cancellation
    windowController.onPrimary = { [weak self] in self?.cancelCurrent() }
    windowController.onSecondary = nil
    renderDownload(present: true)
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    download.expected = expectedContentLength
    renderDownload()
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    download.receive(length)
    renderDownload()
  }

  private func renderDownload(present: Bool = false) {
    guard phase == .downloading else { return }
    let detail = download.fraction.map {
      AppUpdateText.format("download.progress", Int($0 * 100), download.description)
    } ?? download.description
    show(AppUpdatePresentation(title: AppUpdateText.string("download.title"),
                               detail: detail, progress: download.fraction,
                               primaryTitle: AppUpdateText.string("action.cancel")), present: present)
  }

  func showDownloadDidStartExtractingUpdate() {
    cancellation = nil
    windowController.onPrimary = nil
    phase = .extracting
    show(AppUpdatePresentation(title: AppUpdateText.string("verify.title"),
                               detail: AppUpdateText.string("verify.detail"), progress: nil), present: true)
  }

  func showExtractionReceivedProgress(_ progress: Double) {
    guard phase == .extracting else { return }
    let fraction = progress.isFinite ? min(1, max(0, progress)) : nil
    show(AppUpdatePresentation(title: AppUpdateText.string("verify.title"),
                               detail: AppUpdateText.string("verify.detail"), progress: fraction))
  }

  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    waitForInstallation(install: { reply(.install) }, cancel: { reply(.skip) })
  }

  private func waitForInstallation(install: @escaping () -> Void,
                                   cancel: (() -> Void)?, cancelTitle: String = "action.cancel") {
    phase = .waiting
    pendingInstall = install
    pendingCancel = cancel
    cancelTitleKey = cancelTitle
    idleSince = nil
    deferredByUser = false
    windowController.onPrimary = { [weak self] in self?.toggleDeferral() }
    windowController.onSecondary = { [weak self] in self?.cancelCurrent() }
    showWaiting(reason: AppUpdateText.string("waiting.checking"), present: true)
    if usesTimer && timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.pollReadiness() }
      }
    }
    pollReadiness()
  }

  private func showWaiting(reason: String, present: Bool = false) {
    show(AppUpdatePresentation(title: AppUpdateText.string("ready.title"), detail: reason,
                               progress: 1, primaryTitle: AppUpdateText.string(
                                deferredByUser ? "action.resume" : "action.later"),
                               secondaryTitle: pendingCancel == nil ? nil : AppUpdateText.string(cancelTitleKey)),
         present: present)
  }

  func toggleDeferral() {
    guard phase == .waiting else { return }
    deferredByUser.toggle()
    idleSince = nil
    generation += 1
    checkingReadiness = false
    if deferredByUser { showWaiting(reason: AppUpdateText.string("waiting.deferred")) }
    else { pollReadiness() }
  }

  func pollReadiness() {
    guard phase == .waiting, !deferredByUser, !checkingReadiness, !acquiringBarrier else { return }
    checkingReadiness = true
    let token = generation
    activity.readiness { [weak self] readiness in
      guard let self, self.generation == token, self.phase == .waiting else { return }
      self.checkingReadiness = false
      switch readiness {
      case .busy(let reasons):
        self.idleSince = nil
        let message = (reasons.isEmpty ? ["busy.unknown"] : reasons).map(AppUpdateText.string).joined(separator: "\n")
        self.showWaiting(reason: AppUpdateText.format("waiting.busy", message))
      case .ready:
        let instant = self.now()
        if self.idleSince == nil { self.idleSince = instant }
        let remaining = max(0, Int(ceil(10 - instant.timeIntervalSince(self.idleSince!))))
        if remaining > 0 {
          self.showWaiting(reason: AppUpdateText.format("waiting.countdown", remaining))
        } else {
          self.acquireAndInstall()
        }
      }
    }
  }

  private func acquireAndInstall() {
    guard !checkingReadiness, !acquiringBarrier else { return }
    checkingReadiness = true
    acquiringBarrier = true
    let token = generation
    activity.acquireInstallationBarrier { [weak self] readiness in
      guard let self else { return }
      self.acquiringBarrier = false
      guard self.generation == token, self.phase == .waiting, !self.deferredByUser else {
        self.activity.releaseInstallationBarrier()
        return
      }
      self.checkingReadiness = false
      guard readiness == .ready, self.activity.installationBarrierIsSafe else {
        self.activity.releaseInstallationBarrier()
        self.idleSince = nil
        self.showWaiting(reason: AppUpdateText.string("waiting.checking"))
        return
      }
      guard case .supported = self.location() else {
        let cancel = self.pendingCancel
        self.showFailure(detail: AppUpdateText.string("location.move"), shouldPresent: true)
        cancel?()
        return
      }
      let install = self.pendingInstall
      self.pendingInstall = nil
      self.pendingCancel = nil
      self.isInstalling = true
      self.phase = .installing
      self.timer?.invalidate()
      self.timer = nil
      self.showInstallingPresentation()
      install?()
    }
  }

  func cancelCurrent() {
    if let cancel = cancellation {
      clearWork()
      manual = false
      phase = .idle
      windowController.window?.orderOut(nil)
      cancel()
    } else if let cancel = pendingCancel {
      clearWork()
      manual = false
      phase = .idle
      windowController.window?.orderOut(nil)
      cancel()
    }
  }

  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                            retryTerminatingApplication: @escaping () -> Void) {
    retryTermination = applicationTerminated ? nil : retryTerminatingApplication
    if terminationWasVetoed && !applicationTerminated {
      terminationWasVetoed = false
      waitForInstallation(install: retryTerminatingApplication, cancel: nil)
    } else {
      phase = .installing
      showInstallingPresentation()
    }
  }

  private func showInstallingPresentation() {
    windowController.onPrimary = nil
    windowController.onSecondary = nil
    show(AppUpdatePresentation(title: AppUpdateText.string("install.title"),
                               detail: AppUpdateText.string("install.detail"), progress: nil))
  }

  func deferAfterTerminationVeto() {
    isInstalling = false
    activity.releaseInstallationBarrier()
    if let retryTermination {
      waitForInstallation(install: retryTermination, cancel: nil)
    } else {
      terminationWasVetoed = true
    }
  }

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    clearWork()
    manual = false
    phase = .finished
    windowController.window?.orderOut(nil)
    acknowledgement()
  }

  func dismissUpdateInstallation() {
    let keepTerminalMessage = phase == .failed || phase == .finished
    clearWork()
    manual = false
    if !keepTerminalMessage {
      phase = .idle
      windowController.window?.orderOut(nil)
    } else {
      windowController.onPrimary = { [weak self] in
        guard let self else { return }
        if self.phase == .failed { self.retryCheck?() }
        else { self.windowController.window?.orderOut(nil) }
      }
      windowController.onSecondary = { [weak self] in self?.windowController.window?.orderOut(nil) }
    }
  }

  func showUpdateInFocus() { focus() }
}
