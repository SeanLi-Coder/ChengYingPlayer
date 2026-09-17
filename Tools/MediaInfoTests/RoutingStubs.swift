import Cocoa

final class PlayerCore: NSObject {
  final class Info {
    struct State { var active = true }
    var state = State()
    var currentURL: URL?
  }
  let info = Info()
}

class PlayerWindowController: NSWindowController {
  let player = PlayerCore()
}

final class ImageViewerWindowController: NSWindowController {
  var selectedURL: URL?
}

final class MediaInfoWindowController: NSWindowController {
  static weak var latest: MediaInfoWindowController?
  private(set) var currentURL: URL?
  private(set) var presentations = 0
  private(set) var refreshes = 0
  private(set) var closes = 0

  init(reader: @escaping (URL, MediaInfoKind, MediaInfoCancellation) throws -> MediaInfoSnapshot) {
    super.init(window: NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false))
    Self.latest = self
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func present(url: URL, kind: MediaInfoKind, relativeTo: NSWindow?) {
    currentURL = url
    presentations += 1
    window?.orderFront(nil)
  }
  func sourceDidChange(url: URL?, kind: MediaInfoKind) { currentURL = url; refreshes += 1 }
  override func close() { currentURL = nil; closes += 1; super.close() }
}

enum MediaInfoLoader {
  static func read(url: URL, kind: MediaInfoKind, token: MediaInfoCancellation) throws -> MediaInfoSnapshot {
    throw MediaInfoError.cancelled
  }
}

extension Notification.Name {
  static let iinaFileLoaded = Notification.Name("IINAFileLoaded")
  static let iinaPlayerStopped = Notification.Name("iinaPlayerStopped")
}
