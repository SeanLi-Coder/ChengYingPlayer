import Foundation

// Legacy lifecycle/route/preview fixtures explicitly disable persistence. They
// do not emulate receipts, filesystem writes, worker samples, or writer drains.
struct NativePlaybackResumePoint {
  init?(position: Double, duration: Double, speed: Double) {
    precondition(!Preference.bool(for: .resumeLastPosition), "Resume requires the real Core resume fixture")
    return nil
  }
}

final class NativePlaybackResumeReceipt {
  init?(url: URL, generation: UInt64, digest: String, service: NativePlaybackResumeService) {
    precondition(!Preference.bool(for: .resumeLastPosition), "Legacy fixture must explicitly disable resume")
    return nil
  }
  var url: URL { preconditionFailure("No receipt is admitted by this resume-off boundary") }
  var generation: UInt64 { preconditionFailure("No receipt is admitted by this resume-off boundary") }
  var compatibilityRestoreID: UUID? {
    get { preconditionFailure("No receipt is admitted by this resume-off boundary") }
    set { preconditionFailure("No receipt is admitted by this resume-off boundary") }
  }
  func invalidate() { preconditionFailure("No receipt is admitted by this resume-off boundary") }
  func captureFinal(_ point: NativePlaybackResumePoint?) {
    preconditionFailure("Final resume capture requires the real Core resume fixture")
  }
}

final class NativePlaybackResumeService {
  static let shared = NativePlaybackResumeService()
  let store = DisabledStore()
  final class DisabledStore {
    func drain(completion: @escaping () -> Void) {
      preconditionFailure("A saved receipt cannot reach the writer in this resume-off fixture")
    }
  }
}
