import Foundation

/// The UI supplies monotonic timestamps and starts a new dwell only after decoding finishes.
struct ImageSlideshowPolicy {
  static let defaultInterval: TimeInterval = 5
  static let intervalRange: ClosedRange<TimeInterval> = 0.5...120

  private(set) var interval: TimeInterval
  private(set) var isRunning = false
  private(set) var deadline: TimeInterval?
  private var failedURLs = Set<URL>()

  init(interval: TimeInterval = ImageSlideshowPolicy.defaultInterval) {
    self.interval = Self.normalizedInterval(interval) ?? Self.defaultInterval
  }

  /// Reject malformed durations; clamp positive finite values to the supported range.
  static func normalizedInterval(_ value: TimeInterval) -> TimeInterval? {
    guard value.isFinite, value > 0 else { return nil }
    return min(max(value, intervalRange.lowerBound), intervalRange.upperBound)
  }

  /// No row index is retained, so sorting cannot change the identity of the displayed image.
  static func nextIndex(current: Int, count: Int, loops: Bool) -> Int? {
    guard count > 0, current >= 0, current < count else { return nil }
    return current == count - 1 ? (loops ? 0 : nil) : current + 1
  }

  @discardableResult
  mutating func start(now: TimeInterval, imageIsReady: Bool) -> Bool {
    guard now.isFinite else { stop(); return false }
    failedURLs.removeAll()
    isRunning = true
    deadline = imageIsReady ? nextDeadline(after: now) : nil
    if imageIsReady, deadline == nil { stop(); return false }
    return true
  }

  mutating func stop() {
    isRunning = false
    deadline = nil
    failedURLs.removeAll()
  }

  /// Loading time, including a slow animated image's first frame, is not viewing time.
  mutating func imageWillLoad() {
    deadline = nil
  }

  @discardableResult
  mutating func imageDidDisplay(now: TimeInterval) -> Bool {
    failedURLs.removeAll()
    guard isRunning else { return false }
    guard let next = nextDeadline(after: now) else { stop(); return false }
    deadline = next
    return true
  }

  /// Editing an interval restarts the current dwell, but never schedules an unfinished decode.
  @discardableResult
  mutating func setInterval(_ value: TimeInterval, now: TimeInterval) -> Bool {
    guard let value = Self.normalizedInterval(value), now.isFinite else { return false }
    let needsDeadline = isRunning && deadline != nil
    let next = needsDeadline ? nextDeadline(after: now, interval: value) : nil
    guard !needsDeadline || next != nil else { return false }
    interval = value
    deadline = next
    return true
  }

  /// A due timer can advance exactly once until the next image is actually displayed.
  mutating func consumeAdvance(now: TimeInterval) -> Bool {
    guard isRunning, now.isFinite, let deadline, now >= deadline else { return false }
    self.deadline = nil
    return true
  }

  /// Failed files are skipped once per unsuccessful pass; an all-broken folder stops safely.
  @discardableResult
  mutating func recordFailure(of url: URL, among candidates: [URL]) -> Bool {
    guard isRunning else { return false }
    deadline = nil
    failedURLs.insert(url)
    if Set(candidates).isSubset(of: failedURLs) {
      stop()
      return false
    }
    return true
  }

  private func nextDeadline(after now: TimeInterval, interval: TimeInterval? = nil) -> TimeInterval? {
    let next = now + (interval ?? self.interval)
    guard now.isFinite, next.isFinite, next > now else { return nil }
    return next
  }
}
