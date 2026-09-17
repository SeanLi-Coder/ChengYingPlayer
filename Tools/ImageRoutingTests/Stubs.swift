import Cocoa

enum Utility {
  static let playableFileExt = ["mp4", "mkv", "mp3", "flac"]
}

final class WelcomeWindow: NSWindowController {
  var loaded = true
  var closeCount = 0
  override func close() { closeCount += 1; super.close() }
}

final class PlayerCore {
  static let playerCores = [PlayerCore()]
  let initialWindow = WelcomeWindow(window: NSWindow())
}

class PlayerWindowController: NSWindowController {}

// The real coordinator is compiled; only its separate image-window implementation is replaced.
final class ImageViewerWindowController: NSWindowController {
  static var instances: [ImageViewerWindowController] = []
  var inputs: [[URL]] = []
  var isBusy = false
  var isSlideshowRunning = false
  var isActiveForUpdate: Bool { isBusy || isSlideshowRunning }
  var cancelCount = 0

  init(urls: [URL]) {
    let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 300, height: 200),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    inputs.append(urls)
    Self.instances.append(self)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func open(urls: [URL]) { inputs.append(urls) }
  func cancelAndClose() { cancelCount += 1; isBusy = false; close() }
}
