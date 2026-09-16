import Cocoa

final class MainWindowController: NSObject {}
final class FlippedView: NSView { override var isFlipped: Bool { true } }
final class VideoTime { var second: Double; init(_ second: Double) { self.second = second } }
enum PlayerState { case loaded, idle, shuttingDown, shutDown; var loaded: Bool { self == .loaded } }
final class PlaybackInfo {
  var state = PlayerState.loaded
  var currentURL: URL?
  var videoDuration: VideoTime? = VideoTime(120)
  var videoPosition: VideoTime? = VideoTime(10)
  var isNetworkResource = false
  var vid: Int? = 1
}
enum MPVProperty { static let eofReached = "eof"; static let timePos = "time" }
enum MPVOption {
  enum PlaybackControl {
    static let pause = "pause", speed = "speed", abLoopA = "a", abLoopB = "b", abLoopCount = "count"
  }
  enum Video { static let videoRotate = "rotation" }
}
enum MPVHook { static let onUnLoad = "unload" }
final class MPVHookValue {
  let block: (@escaping () -> Void) -> Void
  init(withBlock block: @escaping (@escaping () -> Void) -> Void) { self.block = block }
}
final class MPVController {
  var values: [String: Any] = ["time": 10.0, "pause": false, "speed": 1.0, "a": 0.0, "b": 0.0, "count": "0", "rotation": 0]
  var hooks: [MPVHookValue] = []
  var reads = 0
  func getFlag(_ key: String) -> Bool { reads += 1; return values[key] as? Bool ?? false }
  func getDouble(_ key: String) -> Double { reads += 1; return values[key] as? Double ?? 0 }
  func getString(_ key: String) -> String? { reads += 1; return values[key] as? String }
  func getInt(_ key: String) -> Int { reads += 1; return values[key] as? Int ?? 0 }
  func setString(_ key: String, _ value: String) { values[key] = value }
  func setDouble(_ key: String, _ value: Double) { values[key] = value }
  func setInt(_ key: String, _ value: Int) { values[key] = value }
  func addHook(_ name: String, hook: MPVHookValue) { hooks.append(hook) }
}
final class PlayerCore: NSObject {
  let info = PlaybackInfo()
  let mpv = MPVController()
  var videoToolsMediaGeneration: UInt64 = 1
  var lastStepBackwards: Bool?
  func syncPositionIfNeeded() {}
  func togglePause() { mpv.values["pause"] = !mpv.getFlag("pause") }
  func pause() { mpv.values["pause"] = true }
  func resume() { mpv.values["pause"] = false }
  func seek(absoluteSecond: Double) { mpv.values["time"] = absoluteSecond }
  func syncAbLoop() {}
  func frameStep(backwards: Bool) { lastStepBackwards = backwards; mpv.values["time"] = mpv.getDouble("time") + (backwards ? -1.0 : 1.0) / 30 }
  func setSpeed(_ value: Double) { mpv.values["speed"] = value }
}
final class VideoToolsTaskManager {
  static let shared = VideoToolsTaskManager()
  var snapshot: VideoToolsTaskSnapshot?
  var request: VideoToolsRequest?
  @discardableResult
  func start(operation: VideoToolsOperation, inputURL: URL, start: Double?, end: Double?, degrees: Int?, outputDirectory: URL?) throws -> String {
    request = .start(id: "test", operation: operation, inputURL: inputURL, start: start, end: end, degrees: degrees, outputDirectory: outputDirectory)
    return "test"
  }
  func cancelCurrent() {}
}
extension Notification.Name {
  static let iinaFileLoaded = Notification.Name("loaded")
  static let iinaPlayerStopped = Notification.Name("stopped")
}
