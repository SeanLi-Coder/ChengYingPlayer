import Foundation

/// Main-thread adapter for the independent native session. Construct this only
/// after selecting the native backend; construction never changes PlayerCore's
/// current backend and no mpv UI lifecycle events are fabricated here.
final class NativePlaybackTransport: PlaybackTransport {
  let session: NativePlaybackSession
  private(set) var snapshot: NativePlaybackSnapshot?
  var onSnapshot: ((NativePlaybackSnapshot) -> Void)?
  private var pendingVolume: (generation: UInt64?, value: Double)?
  private var pendingRate: (generation: UInt64?, value: Double)?
  private var pendingPause: (generation: UInt64?, value: Bool)?
  private var pendingSeek: (generation: UInt64, afterRevision: UInt64, target: Double)?

  init(session: NativePlaybackSession) {
    dispatchPrecondition(condition: .onQueue(.main))
    self.session = session
    session.onSnapshot = { [weak self] value in
      guard let self else { return }
      let inactive = [.idle, .closed, .failed].contains(value.phase)
      if let pending = self.pendingVolume,
         inactive || pending.generation != value.generation || abs(pending.value - Double(value.volume) * 100) < 0.0001 {
        self.pendingVolume = nil
      }
      if let pending = self.pendingRate,
         inactive || pending.generation != value.generation || abs(pending.value - Double(value.rate)) < 0.0001 {
        self.pendingRate = nil
      }
      if let pending = self.pendingPause,
         inactive || pending.generation != value.generation ||
         (value.phase == .paused && pending.value) || (value.phase == .playing && !pending.value) {
        self.pendingPause = nil
      }
      if let pending = self.pendingSeek,
         inactive || pending.generation != value.generation ||
         (value.revision > pending.afterRevision && [.playing, .paused, .ended].contains(value.phase) &&
          abs(value.position - pending.target) < 0.01) {
        self.pendingSeek = nil
      }
      self.snapshot = value
      self.onSnapshot?(value)
    }
  }

  var kind: PlaybackTransportKind { .native }
  // These are cached snapshots, not synchronized worker queries. Exact A/B
  // capture uses captureCurrentState's asynchronous query, never dispatchSync.
  var volumePercent: Double {
    dispatchPrecondition(condition: .onQueue(.main))
    return pendingVolume?.value ?? Double(snapshot?.volume ?? 0) * 100
  }
  var rate: Double {
    dispatchPrecondition(condition: .onQueue(.main))
    return pendingRate?.value ?? Double(snapshot?.rate ?? 1)
  }
  var isPaused: Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    return pendingPause?.value ?? (snapshot?.phase != .playing)
  }
  var position: Double? {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let snapshot, ![.idle, .closed, .failed, .opening].contains(snapshot.phase) else { return nil }
    return pendingSeek?.target ?? snapshot.position
  }
  var isAtEOF: Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    return snapshot?.phase == .ended
  }

  private var isClosed: Bool { snapshot?.phase == .closed }

  /// Exact marker/preview capture is asynchronous and revision-checked; do not
  /// substitute the periodic UI snapshot for the worker's current clock.
  func captureCurrentState(completion: @escaping (NativePlaybackQueryResult) -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    session.captureCurrentState(completion: completion)
  }

  @discardableResult
  func setPaused(_ paused: Bool, context: PlaybackCommandContext) -> PlaybackTransportResult {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let snapshot, ![.idle, .closed, .failed].contains(snapshot.phase) else { return .unavailable }
    session.setPaused(paused)
    pendingPause = (snapshot.generation, paused)
    return .accepted
  }

  @discardableResult
  func seek(_ request: PlaybackSeekRequest, context: PlaybackCommandContext) -> PlaybackTransportResult {
    dispatchPrecondition(condition: .onQueue(.main))
    guard request.value.isFinite else { return .invalidInput }
    guard let snapshot, [.playing, .paused, .seeking, .ended].contains(snapshot.phase) else { return .unavailable }
    let target: Double
    switch request.reference {
    case .absoluteSeconds:
      guard request.value >= 0 else { return .invalidInput }
      target = request.value
    case .relativeSeconds:
      // This convenience navigation uses the documented last snapshot. It is
      // not an exact frame/marker capture API.
      target = max(0, (pendingSeek?.target ?? snapshot.position) + request.value)
    case .absolutePercent:
      guard (0...100).contains(request.value) else { return .invalidInput }
      guard snapshot.duration.isFinite, snapshot.duration > 0 else { return .unavailable }
      target = snapshot.duration * (request.value / 100)
    }
    guard target.isFinite else { return .invalidInput }
    // Native always gates decoded samples precisely; approximate mpv seeking
    // is not emulated, and mpv-specific timing probes are not forwarded.
    guard session.seek(to: target) else { return .unavailable }
    let bounded = snapshot.duration > 0 ? min(target, max(0, snapshot.duration - 0.000001)) : target
    pendingSeek = (snapshot.generation, snapshot.revision, bounded)
    return .accepted
  }

  @discardableResult
  func setVolumePercent(_ volume: Double, context: PlaybackCommandContext) -> PlaybackTransportResult {
    dispatchPrecondition(condition: .onQueue(.main))
    guard volume.isFinite else { return .invalidInput }
    guard (0...100).contains(volume) else { return .unsupported }
    guard !isClosed else { return .unavailable }
    session.setVolume(Float(volume / 100))
    pendingVolume = (snapshot?.generation, volume)
    return .accepted
  }

  @discardableResult
  func setRate(_ rate: Double, context: PlaybackCommandContext) -> PlaybackTransportResult {
    dispatchPrecondition(condition: .onQueue(.main))
    guard rate.isFinite, rate > 0 else { return .invalidInput }
    guard (0.5...2).contains(rate) else { return .unsupported }
    guard !isClosed else { return .unavailable }
    guard session.setRate(Float(rate)) else { return .unavailable }
    pendingRate = (snapshot?.generation, rate)
    return .accepted
  }
}
