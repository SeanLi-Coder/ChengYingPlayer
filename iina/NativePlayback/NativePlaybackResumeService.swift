import Foundation

struct NativePlaybackResumePoint {
  let position: Double
  let duration: Double
  let speed: Double

  init?(position: Double, duration: Double, speed: Double) {
    guard duration.isFinite, duration > 0, position.isFinite, position >= 0,
          position <= duration + 0.1, speed.isFinite, (0.5...2).contains(speed) else { return nil }
    self.position = min(position, duration)
    self.duration = duration
    self.speed = speed
  }
}

/// A receipt belongs to one opened native medium, not to the mutable Core URL.
/// Retiring for compatibility only captures; an explicit user exit arms saving.
final class NativePlaybackResumeReceipt {
  let url: URL
  let generation: UInt64
  let recentRecordsEpoch: UInt64
  let progressRecordsEpoch: UInt64
  var compatibilityRestoreID: UUID?
  private let store: NativePlaybackResumeStore
  private let ticket: NativePlaybackResumeTicket?
  private(set) var point: NativePlaybackResumePoint?
  private(set) var saveRequested = false
  private(set) var isReplacement = false
  private(set) var result: NativePlaybackResumeResult?
  private var captured = false
  private var hasPointOverride = false
  private var saving = false
  private var finished = false
  private var resultDelivered = false
  private var completions: [() -> Void] = []

  init(url: URL, generation: UInt64, digest: String, service: NativePlaybackResumeService) {
    self.url = url
    self.generation = generation
    store = service.store
    recentRecordsEpoch = service.recentRecordsEpoch
    progressRecordsEpoch = service.progressRecordsEpoch
    ticket = service.store.begin(digest: digest, owner: UUID(), mediaGeneration: generation)
  }

  func requestSave(replacement: Bool, overriding point: NativePlaybackResumePoint?, authoritative: Bool = false) {
    precondition(Thread.isMainThread)
    guard !finished, !saving else { return }
    if !saveRequested { isReplacement = replacement }
    saveRequested = true
    if authoritative || point != nil {
      self.point = point
      hasPointOverride = true
    }
  }

  func captureFinal(_ point: NativePlaybackResumePoint?) {
    precondition(Thread.isMainThread)
    guard !captured else { return }
    captured = true
    if !hasPointOverride { self.point = point }
    if !completions.isEmpty { attemptFinish() }
  }

  /// Call after the session's final callback, or after a later compatibility exit
  /// has selected its owned restore point. Never waits synchronously on main.
  func finishIfRequested(completion: @escaping () -> Void) {
    precondition(Thread.isMainThread)
    guard saveRequested, !finished else { completion(); return }
    completions.append(completion)
    attemptFinish()
  }

  private func attemptFinish() {
    guard captured else { return }
    guard !saving else { return }
    guard let ticket, let point else { complete(nil); return }
    saving = true
    store.enqueue(ticket, position: point.position, speed: point.speed) { [self] result in
      complete(result)
    }
  }

  func invalidate() {
    precondition(Thread.isMainThread)
    if let ticket { store.invalidate(ticket) }
  }

  /// Multiple exit waiters may complete, but metadata and failure reporting belong
  /// to one finished receipt and must be delivered at most once, including reentry.
  func claimResultDelivery() -> Bool {
    precondition(Thread.isMainThread)
    guard finished, !resultDelivered else { return false }
    resultDelivered = true
    return true
  }

  private func complete(_ result: NativePlaybackResumeResult?) {
    self.result = result
    finished = true
    saving = false
    let pending = completions
    completions.removeAll()
    pending.forEach { $0() }
  }
}

/// Owns the application preference boundary; the filesystem store itself has no
/// dependency on real user defaults or on a player/window lifetime.
final class NativePlaybackResumeService: NSObject {
  static let shared = NativePlaybackResumeService(rootURL: Utility.watchLaterURL, defaults: .standard)

  let store: NativePlaybackResumeStore
  private let defaults: UserDefaults
  private let preferenceKey = Preference.Key.resumeLastPosition.rawValue
  private(set) var recentRecordsEpoch: UInt64 = 0
  private(set) var progressRecordsEpoch: UInt64 = 0

  init(rootURL: URL, defaults: UserDefaults) {
    self.defaults = defaults
    store = NativePlaybackResumeStore(rootURL: rootURL,
      initiallyEnabled: defaults.bool(forKey: Preference.Key.resumeLastPosition.rawValue))
    super.init()
    defaults.addObserver(self, forKeyPath: preferenceKey, options: [.new], context: nil)
    // Reconcile the observation-registration boundary, including registered defaults.
    store.setResumeEnabled(defaults.bool(forKey: preferenceKey))
  }

  deinit { defaults.removeObserver(self, forKeyPath: preferenceKey) }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                             change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
    guard keyPath == preferenceKey else {
      super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
      return
    }
    // KVO may arrive off-main. Synchronize opt-out with publication immediately,
    // not via a delayed main dispatch which could resurrect a queued record.
    if let enabled = change?[.newKey] as? NSNumber, !enabled.boolValue {
      store.setResumeEnabled(false)
    }
    store.setResumeEnabled(defaults.bool(forKey: preferenceKey))
  }

  func invalidateRecentRecords() {
    precondition(Thread.isMainThread)
    recentRecordsEpoch &+= 1
  }

  func clearPlaybackProgress(operation: @escaping () throws -> Void,
                             completion: @escaping (NativePlaybackResumeClearResult) -> Void) {
    precondition(Thread.isMainThread)
    progressRecordsEpoch &+= 1
    store.performClear(operation: operation, completion: completion)
  }
}
