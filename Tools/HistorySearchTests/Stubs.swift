import Cocoa

final class PlaybackHistory: NSObject {
  let url: URL
  let name: String
  let addedDate = Date()
  let duration = VideoTime(100)
  let mpvProgress: VideoTime? = nil
  init(_ path: String) {
    url = URL(fileURLWithPath: path)
    name = url.lastPathComponent
  }
}

final class HistoryController {
  static let shared = HistoryController()
  @Atomic var history: [PlaybackHistory] = []
  func remove(_ entries: [PlaybackHistory]) {
    history.removeAll { entries.contains($0) }
  }
}

@propertyWrapper final class Atomic<Value> {
  var wrappedValue: Value
  var projectedValue: Atomic<Value> { self }
  init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
  func withLock<R>(_ body: (inout Value) -> R) -> R { body(&wrappedValue) }
}

extension Notification.Name {
  static let iinaHistoryUpdated = Notification.Name("HistorySearchTests.updated")
}

enum Utility {
  static func quickAskPanel(_ key: String, sheetWindow: NSWindow?, completion: (NSApplication.ModalResponse) -> Void) {}
  static func icon(for url: URL) -> NSImage { NSImage() }
}

enum KeyCodeHelper {
  static func mpvKeyCode(from event: NSEvent) -> String { "" }
}

enum Logger {
  enum Level { case verbose }
  static func log(_ message: String, level: Level = .verbose) {}
}

final class PlayerCore {
  static let activeOrNew = PlayerCore()
  static let active = PlayerCore()
  static var newPlayerCore: PlayerCore { PlayerCore() }
  func openURL(_ url: URL) {}
}
