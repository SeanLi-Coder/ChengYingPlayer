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
  enum Video {
    static let videoRotate = "rotation"
    static let videoZoom = "video-zoom", videoPanX = "video-pan-x", videoPanY = "video-pan-y"
  }
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
  var intWrites: [String: [Int]] = [:]
  func getFlag(_ key: String) -> Bool { reads += 1; return values[key] as? Bool ?? false }
  func getDouble(_ key: String) -> Double { reads += 1; return values[key] as? Double ?? Double(values[key] as? String ?? "") ?? 0 }
  func getString(_ key: String) -> String? {
    reads += 1
    if let value = values[key] as? String { return value }
    if let value = values[key] as? Double { return String(value) }
    return nil
  }
  func getInt(_ key: String) -> Int { reads += 1; return values[key] as? Int ?? 0 }
  func setString(_ key: String, _ value: String) { values[key] = value }
  func setDouble(_ key: String, _ value: Double) { values[key] = value }
  func setInt(_ key: String, _ value: Int) {
    intWrites[key, default: []].append(value)
    values[key] = value
  }
  func addHook(_ name: String, hook: MPVHookValue) { hooks.append(hook) }
}
final class PlayerCore: NSObject {
  let info = PlaybackInfo()
  let mpv = MPVController()
  var videoToolsMediaGeneration: UInt64 = 1
  var videoToolsLoopRecovery = VideoToolsLoopRecovery()
  var lastStepBackwards: Bool?
  func syncPositionIfNeeded() {}
  func togglePause() { mpv.values["pause"] = !mpv.getFlag("pause") }
  func pause() { mpv.values["pause"] = true }
  func resume() { mpv.values["pause"] = false }
  func seek(absoluteSecond: Double) { mpv.values["time"] = videoToolsLoopRange?.clamped(absoluteSecond) ?? absoluteSecond }
  func syncAbLoop() {}
  func frameStep(backwards: Bool) { lastStepBackwards = backwards; mpv.values["time"] = mpv.getDouble("time") + (backwards ? -1.0 : 1.0) / 30 }
  func setSpeed(_ value: Double) { mpv.values["speed"] = value }
}
final class VideoToolsTaskManager: VideoToolsRotationTaskManaging {
  static let shared = VideoToolsTaskManager()
  var snapshot: VideoToolsTaskSnapshot?
  var request: VideoToolsRequest?
  var requests: [VideoToolsRequest] = []
  var cancellations: [String] = []
  var simulatesTaskLifecycle = false
  var startError: Error?
  @discardableResult
  func start(operation: VideoToolsOperation, inputURL: URL, start: Double?, end: Double?, degrees: Int?, targetFormat: String? = nil, conversionMode: String? = nil, outputDirectory: URL?) throws -> String {
    if snapshot?.isActive == true { throw VideoToolsClientError.busy }
    if let startError { throw startError }
    let id = "test-\(requests.count + 1)"
    let newRequest = VideoToolsRequest.start(id: id, operation: operation, inputURL: inputURL, start: start, end: end, degrees: degrees, targetFormat: targetFormat, conversionMode: conversionMode, outputDirectory: outputDirectory)
    request = newRequest
    requests.append(newRequest)
    if simulatesTaskLifecycle {
      snapshot = VideoToolsTaskSnapshot(
        id: id, operation: operation, inputURL: inputURL, phase: .starting,
        progress: 0, message: "Starting", elapsedSeconds: nil, etaSeconds: nil,
        frameCount: nil, outputURL: nil, errorCode: nil, error: nil
      )
      notifyTaskChange()
    }
    return id
  }
  func cancelCurrent() {
    guard let task = snapshot, task.isActive else { return }
    cancellations.append(task.id)
    finishTask(.cancelling)
  }
  func finishTask(_ phase: VideoToolsTaskPhase, outputURL: URL? = nil) {
    snapshot?.phase = phase
    if phase == .completed {
      snapshot?.progress = 100
      snapshot?.outputURL = outputURL
    } else if phase == .failed {
      snapshot?.error = "Test export failure"
    }
    notifyTaskChange()
  }
  func reportProgress(_ progress: Double) {
    guard snapshot?.isActive == true else { return }
    snapshot?.phase = .running
    snapshot?.progress = progress
    notifyTaskChange()
  }
  func notifyTaskChange() {
    NotificationCenter.default.post(name: .videoToolsTaskChanged, object: self)
  }
  func startRotation(inputURL: URL, degrees: Int) throws -> String {
    try start(operation: .rotate, inputURL: inputURL, start: nil, end: nil, degrees: degrees, outputDirectory: nil)
  }
  func cancelRotation(taskID: String) {
    guard snapshot?.id == taskID else { return }
    cancelCurrent()
  }
}
extension Notification.Name {
  static let iinaFileLoaded = Notification.Name("loaded")
  static let iinaPlayerStopped = Notification.Name("stopped")
}
