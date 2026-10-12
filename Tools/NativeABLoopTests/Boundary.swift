import AppKit

// Only application services and legacy MPV are doubles. Commands under test,
// marker capture, decoder, session, sample gate and audio/video output are real.
enum LoopMode { case off, file, playlist }
enum Preference {
  enum Key { case useExactSeek }
  enum SeekOption { case auto, exact, relative }
  static func bool(for key: Key) -> Bool { true }
}
final class VideoTime {
  let second: Double
  init(_ value: Double) { second = value }
  var stringRepresentation: String { String(second) }
}
enum ABLoopStatus { case cleared, aSet, bSet }
enum TestState {
  case loaded, paused, idle, shuttingDown, shutDown
  var loaded: Bool { self == .loaded }
  var active: Bool { loaded }
}
final class PlaybackInfo {
  var state = TestState.loaded
  var currentURL: URL?
  var videoDuration: VideoTime?
  var videoPosition: VideoTime?
  var vid: Int? = 1
  var abLoopStatus = ABLoopStatus.cleared
}
final class MainWindowDouble {
  let loaded = true
  var syncCount = 0
  func syncSlider() { syncCount += 1 }
}
enum OSDMessage { case abLoop(ABLoopStatus), abLoopUpdate(ABLoopStatus, String), custom(String) }
final class MPVDouble {
  var mpv: Int? = 1
  var values: [String: Any] = [:]
  var writes = 0
  var reads = 0
  func getString(_ key: String) -> String? {
    reads += 1
    return values[key].map { String(describing: $0) }
  }
  func getDouble(_ key: String) -> Double { reads += 1; return values[key] as? Double ?? 0 }
  func getFlag(_ key: String) -> Bool { reads += 1; return values[key] as? Bool ?? false }
  func getInt(_ key: String) -> Int { reads += 1; return values[key] as? Int ?? 0 }
  func setString(_ key: String, _ value: String) { writes += 1; values[key] = value }
  func setDouble(_ key: String, _ value: Double) { writes += 1; values[key] = value }
  func setInt(_ key: String, _ value: Int) { writes += 1; values[key] = value }
  func setFlag(_ key: String, _ value: Bool) { writes += 1; values[key] = value }
}
final class MarkerDouble { var isHidden = false; var doubleValue = 0.0 }
final class SliderDouble {
  let abLoopA = MarkerDouble()
  let abLoopB = MarkerDouble()
  var needsDisplay = false
}
extension Double {
  func clamped(to range: Range<Double>) -> Double { min(range.upperBound.nextDown, max(range.lowerBound, self)) }
}
