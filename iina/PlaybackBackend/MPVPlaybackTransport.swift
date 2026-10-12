import Foundation

/// Maps typed commands to existing mpv operations without taking over its
/// property-change events, automatic-seek timing, or error-reporting policy.
final class MPVPlaybackTransport: PlaybackTransport {
  struct Sink {
    let isAvailable: () -> Bool
    let getFlag: (String) -> Bool
    let getDouble: (String) -> Double
    let setFlag: (String, Bool, PlaybackCommandVerbosity) -> Void
    let setDouble: (String, Double, PlaybackCommandVerbosity) -> Void
    let command: (String, [String], PlaybackCommandContext) -> Void
  }

  private let sink: Sink
  init(sink: Sink) { self.sink = sink }

  var kind: PlaybackTransportKind { .mpv }
  var volumePercent: Double { sink.isAvailable() ? sink.getDouble("volume") : 0 }
  var rate: Double { sink.isAvailable() ? sink.getDouble("speed") : 1 }
  var isPaused: Bool { sink.isAvailable() ? sink.getFlag("pause") : true }
  var position: Double? {
    guard sink.isAvailable() else { return nil }
    let value = sink.getDouble("time-pos")
    return value.isFinite ? value : nil
  }
  var isAtEOF: Bool { sink.isAvailable() ? sink.getFlag("eof-reached") : false }

  @discardableResult
  func setPaused(_ paused: Bool, context: PlaybackCommandContext) -> PlaybackTransportResult {
    guard sink.isAvailable() else { return .unavailable }
    sink.setFlag("pause", paused, context.verbosity)
    return .accepted
  }

  @discardableResult
  func seek(_ request: PlaybackSeekRequest, context: PlaybackCommandContext) -> PlaybackTransportResult {
    guard request.value.isFinite else { return .invalidInput }
    guard sink.isAvailable() else { return .unavailable }
    let reference: String
    switch request.reference {
    case .absoluteSeconds: reference = "absolute"
    case .relativeSeconds: reference = "relative"
    case .absolutePercent: reference = "absolute-percent"
    }
    let mode = reference + (request.exact ? "+exact" : "")
    sink.command("seek", ["\(request.value)", mode], context)
    return .accepted
  }

  @discardableResult
  func setVolumePercent(_ volume: Double, context: PlaybackCommandContext) -> PlaybackTransportResult {
    guard volume.isFinite else { return .invalidInput }
    guard sink.isAvailable() else { return .unavailable }
    // PlayerCore owns user preference clamping. Preserve its explicit
    // unconstrained-volume path and mpv's existing amplification support.
    sink.setDouble("volume", volume, context.verbosity)
    return .accepted
  }

  @discardableResult
  func setRate(_ rate: Double, context: PlaybackCommandContext) -> PlaybackTransportResult {
    guard rate.isFinite, rate > 0 else { return .invalidInput }
    guard sink.isAvailable() else { return .unavailable }
    sink.setDouble("speed", rate, context.verbosity)
    return .accepted
  }
}
