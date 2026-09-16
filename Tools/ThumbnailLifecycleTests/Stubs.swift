import Foundation

enum Logger { enum Level { case debug, warning, error } }
enum Preference {
  enum Key { case enableThumbnailForRemoteFiles, enableThumbnailPreview, thumbnailWidth }
  static var enabled = true
  static var width = 240
  static func bool(for key: Key) -> Bool { key == .enableThumbnailForRemoteFiles || enabled }
  static func integer(for key: Key) -> Int { width }
}
final class FFThumbnail {
  let marker: Int
  init(_ marker: Int) { self.marker = marker }
}
protocol FFmpegControllerDelegate {
  func didUpdate(_ thumbnails: [FFThumbnail]?, forFile filename: String, withProgress progress: Int, generation: UInt)
  func didGenerate(_ thumbnails: [FFThumbnail], forFile filename: String, succeeded: Bool, generation: UInt)
}
final class ThumbnailDecoderFixture {
  struct Request { let file: String; let width: Int32; let generation: UInt }
  var requests = [Request]()
  var cancellations = 0
  var thumbnailCount = 100
  func cancelThumbnailGeneration() { precondition(Thread.isMainThread); cancellations += 1 }
  func generateThumbnail(forFile file: String, thumbWidth: Int32, generation: UInt) {
    precondition(Thread.isMainThread)
    requests.append(Request(file: file, width: thumbWidth, generation: generation))
  }
}
final class ThumbnailInfoFixture {
  var state = PlayerState.playing
  var currentURL: URL? = URL(fileURLWithPath: "/nonexistent-chengying-thumbnail-tests/first.mp4")
  var isNetworkResource = false
  var mpvMd5: String? = "first-cache"
  @Atomic var thumbnails = [FFThumbnail]()
  var thumbnailsReady = false { didSet { precondition(Thread.isMainThread) } }
  var thumbnailsProgress = 0.0 { didSet { precondition(Thread.isMainThread) } }
}
final class SliderFixture {
  var resets = 0
  func resetCachedThumbnails() { precondition(Thread.isMainThread); resets += 1 }
}
final class TouchBarFixture { var touchBarPlaySlider: SliderFixture? = SliderFixture() }
final class EventFixture {
  enum Event { case thumbnailsReady }
  var count = 0
  func emit(_ event: Event) { precondition(Thread.isMainThread); count += 1 }
}
final class NowPlayingInfoManager {
  static let shared = NowPlayingInfoManager()
  var count = 0
  func updateInfo() { precondition(Thread.isMainThread); count += 1 }
}
enum ThumbnailCache {
  struct Write { let markers: [Int]; let name: String; let url: URL? }
  static let lock = Lock()
  private static var cached = false
  private static var readBody: () -> [FFThumbnail]? = { nil }
  private static var writes = [Write]()
  static func configure(cached value: Bool, read: @escaping () -> [FFThumbnail]? = { nil }) {
    lock.withLock { cached = value; readBody = read; writes = [] }
  }
  static func fileIsCached(forName name: String, forVideo url: URL?) -> Bool { lock.withLock { cached } }
  static func read(forName name: String) -> [FFThumbnail]? {
    precondition(!Thread.isMainThread)
    return lock.withLock { readBody }()
  }
  static func write(_ thumbnails: [FFThumbnail], forName name: String, forVideo url: URL?) {
    precondition(!Thread.isMainThread)
    lock.withLock { writes.append(Write(markers: thumbnails.map(\.marker), name: name, url: url)) }
  }
  static func snapshot() -> [Write] { lock.withLock { writes } }
}
class ThumbnailPlayerFixture {
  let info = ThumbnailInfoFixture()
  let ffmpegController = ThumbnailDecoderFixture()
  let touchBarSupport = TouchBarFixture()
  let events = EventFixture()
  let thumbnailQueue = DispatchQueue(label: "ThumbnailLifecycleTests.disk")
  var refreshes = 0
  func log(_ message: String, level: Logger.Level = .debug) {}
  func refreshTouchBarSlider() { precondition(Thread.isMainThread); refreshes += 1 }
}
