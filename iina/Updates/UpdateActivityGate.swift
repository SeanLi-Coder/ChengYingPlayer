import AppKit

/// Main-thread admission and a backend lease close the check-to-install race.
@MainActor
final class UpdateActivityGate: UpdateActivityChecking {
  static let shared = UpdateActivityGate()

  struct Dependencies {
    var localReasons: () -> [String]
    var downloadActivity: (@escaping (Bool?) -> Void) -> Void
    var acquireDownloads: (UUID, @escaping (Bool) -> Void) -> Void
    var releaseDownloads: (UUID) -> Void
    var drainHelpers: (UUID, @escaping (Bool) -> Void) -> Void
  }

  private let dependencies: Dependencies
  private let admission: UpdateWorkAdmission
  private var barrier: UUID?
  private var installationReady = false

  init(dependencies: Dependencies? = nil, admission: UpdateWorkAdmission = .shared) {
    self.dependencies = dependencies ?? Self.productionDependencies()
    self.admission = admission
  }

  var installationBarrierIsSafe: Bool {
    barrier != nil && installationReady && admission.isBlocked &&
      !admission.hasDrainingProcesses && dependencies.localReasons().isEmpty
      && admission.activeReasons.isEmpty
  }

  func readiness(completion: @escaping (UpdateReadiness) -> Void) {
    let local = localReasons()
    guard local.isEmpty, barrier == nil else {
      completion(.busy(local.isEmpty ? ["busy.unknown"] : local)); return
    }
    dependencies.downloadActivity { [weak self] busy in
      guard let self else { completion(.busy(["busy.unknown"])); return }
      var reasons = self.localReasons()
      if self.barrier != nil { reasons.append("busy.unknown") }
      if let busy { if busy { reasons.append("busy.downloads") } }
      else { reasons.append("busy.unknown") }
      completion(reasons.isEmpty ? .ready : .busy(reasons))
    }
  }

  func acquireInstallationBarrier(completion: @escaping (UpdateReadiness) -> Void) {
    let reasons = localReasons()
    let identifier = UUID()
    guard reasons.isEmpty, barrier == nil, admission.acquire(identifier) else {
      completion(.busy(reasons.isEmpty ? ["busy.unknown"] : reasons)); return
    }
    barrier = identifier
    installationReady = false
    dependencies.acquireDownloads(identifier) { [weak self] acquired in
      guard let self, self.barrier == identifier else {
        completion(.busy(["busy.unknown"])); return
      }
      guard acquired, self.dependencies.localReasons().isEmpty else {
        self.releaseInstallationBarrier()
        completion(.busy([acquired ? "busy.unknown" : "busy.downloads"])); return
      }
      self.dependencies.drainHelpers(identifier) { [weak self] success in
        guard let self, self.barrier == identifier else {
          completion(.busy(["busy.unknown"])); return
        }
        guard success, self.localReasons().isEmpty else {
          self.releaseInstallationBarrier()
          completion(.busy(["busy.unknown"])); return
        }
        self.installationReady = true
        completion(.ready)
      }
    }
  }

  func releaseInstallationBarrier() {
    guard let identifier = barrier else { return }
    installationReady = false
    barrier = nil
    dependencies.releaseDownloads(identifier)
    admission.release(identifier)
  }

  private func localReasons() -> [String] {
    var reasons = Array(Set(dependencies.localReasons() + admission.activeReasons)).sorted()
    if admission.hasDrainingProcesses { reasons.append("busy.unknown") }
    return reasons
  }

  private static func productionDependencies() -> Dependencies {
    Dependencies(localReasons: {
      var reasons = [String]()
      if NSApp?.modalWindow != nil || NSApp?.windows.contains(where: { $0.attachedSheet != nil }) == true {
        reasons.append("busy.unknown")
      }
      // Paused and loading media also represent an unfinished viewing session.
      if PlayerCore.playerCores.contains(where: { $0.info.state.active || $0.info.state == .stopping }) {
        reasons.append("busy.playback")
      }
      if VideoToolsTaskManager.shared.snapshot?.isActive == true || VideoToolsRotationCoordinator.hasPendingUpdateWork {
        reasons.append("busy.videoTask")
      }
      if SubtitleToolsService.shared.task?.isActive == true { reasons.append("busy.subtitles") }
      if ImageViewerCoordinator.shared.isActiveForUpdate { reasons.append("busy.images") }
      if VideoToolsHelperClient.shared.updateActivityIsUncertain || SubtitleToolsService.shared.updateActivityIsUncertain {
        reasons.append("busy.unknown")
      }
      return reasons
    }, downloadActivity: { completion in
      DownloadCenterService.shared.updateActivity(completion: completion)
    }, acquireDownloads: { identifier, completion in
      DownloadCenterService.shared.acquireUpdateLease(identifier, completion: completion)
    }, releaseDownloads: { identifier in
      DownloadCenterService.shared.releaseUpdateLease(identifier)
    }, drainHelpers: { identifier, completion in
      var remaining = 3
      var allSucceeded = true
      let finished: (Bool) -> Void = { success in
        precondition(Thread.isMainThread)
        allSucceeded = allSucceeded && success
        remaining -= 1
        if remaining == 0 { completion(allSucceeded) }
      }
      VideoToolsHelperClient.shared.shutdownForUpdate(completion: finished)
      SubtitleToolsService.shared.shutdownForUpdate(completion: finished)
      DownloadCenterService.shared.shutdownForUpdate(identifier, completion: finished)
    })
  }
}
