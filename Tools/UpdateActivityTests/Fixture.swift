import Foundation

final class PlayerCore {
  static var playerCores = [PlayerCore]()
  struct Info { var state: PlayerState = .idle }
  var info = Info()
}
final class VideoToolsTaskManager {
  static let shared = VideoToolsTaskManager()
  struct Snapshot { var isActive = false }
  var snapshot: Snapshot?
}
enum VideoToolsRotationCoordinator { static var hasPendingUpdateWork = false }
final class VideoToolsHelperClient {
  static let shared = VideoToolsHelperClient()
  var updateActivityIsUncertain = false
  func shutdownForUpdate(completion: @escaping (Bool) -> Void) { completion(true) }
}
final class SubtitleToolsService {
  static let shared = SubtitleToolsService()
  var task: VideoToolsTaskManager.Snapshot?
  var updateActivityIsUncertain = false
  func shutdownForUpdate(completion: @escaping (Bool) -> Void) { completion(true) }
}
final class ImageViewerCoordinator {
  static let shared = ImageViewerCoordinator()
  var isActiveForUpdate = false
}
final class DownloadCenterService {
  static let shared = DownloadCenterService()
  var activity: Bool? = false
  var acquired = false
  func updateActivity(completion: @escaping (Bool?) -> Void) { completion(activity) }
  func acquireUpdateLease(_ id: UUID, completion: @escaping (Bool) -> Void) { acquired = true; completion(true) }
  func releaseUpdateLease(_ id: UUID) { acquired = false }
  func shutdownForUpdate(_ id: UUID, completion: @escaping (Bool) -> Void) { completion(true) }
}

@MainActor
final class GateFixture {
  let admission = UpdateWorkAdmission()
  var local = [String]()
  var activity: ((Bool?) -> Void)?
  var acquire: ((Bool) -> Void)?
  var drain: ((Bool) -> Void)?
  var leases = [UUID]()
  var released = [UUID]()
  var drainCount = 0
  lazy var gate = UpdateActivityGate(dependencies: .init(localReasons: { self.local }, downloadActivity: {
    self.activity = $0
  }, acquireDownloads: { id, callback in
    self.leases.append(id); self.acquire = callback
  }, releaseDownloads: { self.released.append($0) }, drainHelpers: { _, callback in
    self.drainCount += 1; self.drain = callback
  }), admission: admission)
}
