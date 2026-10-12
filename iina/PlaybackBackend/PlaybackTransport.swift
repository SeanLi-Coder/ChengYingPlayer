import Foundation

enum PlaybackTransportKind { case mpv, native }

enum PlaybackTransportResult: Equatable {
  // Accepted means dispatched, not that asynchronous playback has completed.
  case accepted, invalidInput, unsupported, unavailable
}

enum PlaybackCommandVerbosity { case debug, verbose }

struct PlaybackCommandContext {
  var checkError = true
  var verbosity: PlaybackCommandVerbosity = .debug
  var seekTimingGeneration: UInt64?
}

struct PlaybackSeekRequest: Equatable {
  enum Reference { case absoluteSeconds, relativeSeconds, absolutePercent }
  let value: Double
  let reference: Reference
  let exact: Bool
}

/// Typed control boundary only. It does not own media loading, surfaces, or UI
/// lifecycle events. MPV queries remain synchronous live property reads; native
/// queries explicitly expose the last published session snapshot instead.
protocol PlaybackTransport: AnyObject {
  var kind: PlaybackTransportKind { get }
  var volumePercent: Double { get }
  var rate: Double { get }
  var isPaused: Bool { get }
  var position: Double? { get }
  var isAtEOF: Bool { get }

  @discardableResult func setPaused(_ paused: Bool, context: PlaybackCommandContext) -> PlaybackTransportResult
  @discardableResult func seek(_ request: PlaybackSeekRequest, context: PlaybackCommandContext) -> PlaybackTransportResult
  @discardableResult func setVolumePercent(_ volume: Double, context: PlaybackCommandContext) -> PlaybackTransportResult
  @discardableResult func setRate(_ rate: Double, context: PlaybackCommandContext) -> PlaybackTransportResult
}

extension PlaybackTransport {
  @discardableResult func setPaused(_ paused: Bool) -> PlaybackTransportResult {
    setPaused(paused, context: PlaybackCommandContext())
  }
  @discardableResult func seek(_ request: PlaybackSeekRequest) -> PlaybackTransportResult {
    seek(request, context: PlaybackCommandContext())
  }
  @discardableResult func setVolumePercent(_ volume: Double) -> PlaybackTransportResult {
    setVolumePercent(volume, context: PlaybackCommandContext())
  }
  @discardableResult func setRate(_ rate: Double) -> PlaybackTransportResult {
    setRate(rate, context: PlaybackCommandContext())
  }
}
