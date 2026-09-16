import Foundation

// Only OS/player boundaries are doubled. The production task registration,
// completion, stop, shutdown, and filter pointer operations are extracted verbatim.
enum Logger {
  enum Level { case debug, error, verbose }
  static func ensure(_ condition: Bool, _ message: String) { precondition(condition, message) }
}

@propertyWrapper final class Atomic<Value> {
  private let lock = NSLock()
  private var value: Value
  init(wrappedValue: Value) { value = wrappedValue }
  var projectedValue: Atomic<Value> { self }
  var wrappedValue: Value {
    get { lock.lock(); defer { lock.unlock() }; return value }
    set { lock.lock(); defer { lock.unlock() }; value = newValue }
  }
  func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }
}

enum MediaStatus { case unknown }
enum TrackType { case sub }
enum UIUpdate { case time }
enum MPVCommand { case stop }
enum MPVOption {
  enum PlaybackControl { static let pause = "pause" }
}
enum MPVProperty {
  static let vf = "vf"
  static let af = "af"
}
struct MPVFilter {
  let name: String
  let label: String?
  let params: [String: String]?
}

final class PlaybackFixture {
  var state = PlayerState.playing
  var currentURL: URL?
  var isNetworkResource = false
  var justStartedFile = false
  var disableOSDForFileLoading = false
  var shouldAutoLoadFiles = true
  var thumbnails = [Int]()
  var thumbnailsReady = false
  var thumbnailsProgress = 0.0
  @Atomic var matchedSubs = [String: [URL]]()
  func getMatchedSubs(_ path: String) -> [URL]? { nil }
}

final class PlaybackMPV {
  var stopped = 0
  var quit = 0
  var paused = false
  func getFlag(_ name: String) -> Bool { paused }
  func setFlag(_ name: String, _ value: Bool, level: Logger.Level) { paused = value }
  func command(_ command: MPVCommand, level: Logger.Level) { stopped += 1 }
  func mpvQuit() { quit += 1 }
}

final class VideoFixture {
  var stops = 0
  func stopDisplayLink() { stops += 1 }
}
final class WindowFixture { let videoView = VideoFixture() }
final class ThumbnailDecoderFixture {
  var cancellations = 0
  func cancelThumbnailGeneration() { cancellations += 1 }
}
final class ThumbnailSliderFixture {
  func resetCachedThumbnails() {}
}
final class TouchBarFixture { var touchBarPlaySlider: ThumbnailSliderFixture? }
final class EventFixture {
  enum Event { case fileStarted }
  func emit(_ event: Event) {}
}
final class NowPlayingInfoManager {
  static let shared = NowPlayingInfoManager()
  func updateInfo(withTitle: Bool) {}
}
extension CharacterSet { static let urlAllowed = CharacterSet.urlFragmentAllowed }
extension Data {
  init<T>(bytesOf values: [T]) {
    self = values.withUnsafeBytes { Data($0) }
  }
}

class PlayerFixture {
  let info = PlaybackFixture()
  let mpv = PlaybackMPV()
  let mainWindow = WindowFixture()
  let events = EventFixture()
  let ffmpegController = ThumbnailDecoderFixture()
  let touchBarSupport = TouchBarFixture()
  let backgroundQueue = DispatchQueue(label: "PlaybackLifecycleTests.matcher")
  var videoToolsMediaGeneration: UInt64 = 0
  var currentMediaIsAudio = MediaStatus.unknown
  var taskBody: (Int) throws -> Void = { _ in }
  var finishedTasks = 0
  func log(_ message: String, level: Logger.Level = .debug) {
    if message == "Background task has stopped" {
      precondition(Thread.isMainThread)
      finishedTasks += 1
    }
  }
  func videoToolsClearLoop() {}
  func loadExternalSubFile(_ url: URL) {}
  func setTrack(_ id: Int, forType: TrackType) {}
  func autoLoadFilesInCurrentFolder(ticket: Int) throws { try taskBody(ticket) }
  func savePlaybackPosition() {}
  func refreshSyncUITimer() {}
  func savePlayerState() {}
}

// POD equivalents of the C node layout allow boundary failures to be injected
// deterministically without a running decoder or a downloaded libmpv dependency.
let MPV_FORMAT_NONE: Int32 = 0
let MPV_FORMAT_NODE: Int32 = 6
let MPV_FORMAT_NODE_ARRAY: Int32 = 7
let MPV_FORMAT_NODE_MAP: Int32 = 8
struct NodeUnion {
  var list: UnsafeMutablePointer<mpv_node_list>?
  var int64: Int64 = 0
}
struct mpv_node {
  var format = MPV_FORMAT_NONE
  var u = NodeUnion()
}
struct mpv_node_list {
  var num: Int32 = 0
  var values: UnsafeMutablePointer<mpv_node>?
}

final class FilterMPV {
  enum ReadMode { case valid, unavailable, wrongFormat, missingList, missingValues }
  var mode = ReadMode.valid
  var values: [Int64] = [11, 22, 33]
  var writeSucceeds = true
  var writes = 0
  var reads = 0
  static var releases = 0
}

enum MPVNode {
  static var parsedValue: Any? = [["name": "hflip"] as [String: Any?]]
  static var throwsOnParse = false
  enum ParseError: Error { case invalid }
  static func parse(_ node: mpv_node) throws -> Any? {
    if throwsOnParse { throw ParseError.invalid }
    return node.format == MPV_FORMAT_NONE ? nil : parsedValue
  }
}

func mpv_get_property(_ handle: FilterMPV?, _ name: String, _ format: Int32,
                      _ output: inout mpv_node) -> Int32 {
  guard let handle else { return -1 }
  handle.reads += 1
  guard handle.mode != .unavailable else { return -1 }
  output.format = handle.mode == .wrongFormat ? MPV_FORMAT_NODE_MAP : MPV_FORMAT_NODE_ARRAY
  guard handle.mode != .missingList else { return 0 }
  let list = UnsafeMutablePointer<mpv_node_list>.allocate(capacity: 1)
  var value = mpv_node_list()
  value.num = Int32(handle.values.count)
  if handle.mode != .missingValues {
    let items = UnsafeMutablePointer<mpv_node>.allocate(capacity: handle.values.count)
    for (index, identifier) in handle.values.enumerated() {
      items.advanced(by: index).initialize(to: mpv_node(format: MPV_FORMAT_NODE, u: NodeUnion(int64: identifier)))
    }
    value.values = items
  }
  list.initialize(to: value)
  output.u.list = list
  return 0
}

func mpv_free_node_contents(_ node: inout mpv_node) {
  FilterMPV.releases += 1
  guard let list = node.u.list else { return }
  if let values = list.pointee.values {
    values.deinitialize(count: Int(list.pointee.num))
    values.deallocate()
  }
  list.deinitialize(count: 1)
  list.deallocate()
  node = mpv_node()
}

func mpv_set_property(_ handle: FilterMPV?, _ name: String, _ format: Int32,
                      _ node: inout mpv_node) -> Int32 {
  guard let handle else { return -1 }
  handle.writes += 1
  guard handle.writeSucceeds else { return -1 }
  let list = node.u.list!.pointee
  handle.values = (0..<Int(list.num)).map { list.values![$0].u.int64 }
  return 0
}
