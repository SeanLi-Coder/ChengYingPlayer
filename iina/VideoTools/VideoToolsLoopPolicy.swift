//
//  VideoToolsLoopPolicy.swift
//  ChengYing
//

import Foundation

/// A half-open playback interval. Zero is a valid A marker; only nil means unset.
struct VideoToolsLoopRange: Equatable {
  let start: Double
  let end: Double

  init?(start: Double?, end: Double?, duration: Double? = nil) {
    guard let start, let end, start.isFinite, end.isFinite,
          start >= 0, end > start else { return nil }
    if let duration, duration.isFinite, duration > 0, end > duration { return nil }
    self.start = start
    self.end = end
  }

  /// Leave a small interior margin because mpv timestamps are rounded to microseconds.
  var lastSeekPosition: Double { max(start, end - min(0.001, (end - start) / 2)) }

  func contains(_ position: Double) -> Bool {
    position.isFinite && position >= start && position < end
  }

  func clamped(_ position: Double) -> Double {
    guard position.isFinite else { return start }
    return min(lastSeekPosition, max(start, position))
  }

  static func marker(from option: String?) -> Double? {
    guard let option, let value = Double(option), value.isFinite, value >= 0 else { return nil }
    return value
  }
}

/// Event-driven recovery avoids seek storms for damaged files or intervals with no decodable frame.
struct VideoToolsLoopRecovery {
  private(set) var pendingTarget: Double?
  private(set) var failures = 0
  private(set) var suspended = false

  mutating func reset() { self = VideoToolsLoopRecovery() }
  mutating func userSeek(to target: Double) {
    reset()
    pendingTarget = target
  }
  mutating func didRestart() { pendingTarget = nil }
  mutating func reachedRange() { reset() }
  mutating func beginCorrection(to target: Double) -> Bool {
    guard pendingTarget == nil, !suspended else { return false }
    guard failures < 3 else { suspended = true; return false }
    failures += 1
    pendingTarget = target
    return true
  }
}
