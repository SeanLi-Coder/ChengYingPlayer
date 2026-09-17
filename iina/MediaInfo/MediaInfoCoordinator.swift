import Cocoa

/// Route information to the foreground media owner, never an unrelated background player.
final class MediaInfoCoordinator: NSObject, NSMenuItemValidation {
  static let shared = MediaInfoCoordinator()
  private let panel: MediaInfoWindowController
  private weak var owner: NSWindow?
  private var observers: [NSObjectProtocol] = []

  override init() {
    panel = MediaInfoWindowController(reader: MediaInfoLoader.read)
    super.init()
    let center = NotificationCenter.default
    for name in [Notification.Name.chengyingImageSourceChanged, .chengyingMediaSourceChanged,
                 .iinaFileLoaded, .iinaPlayerStopped] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        self?.sourceChanged(note)
      })
    }
    observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
      guard let self, self.panel.isWindowLoaded, self.panel.window?.isVisible == true,
            let window = note.object as? NSWindow, self.kind(for: window) != nil else { return }
      self.owner = window
      self.refreshOwner()
    })
    observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
      guard let self, let window = note.object as? NSWindow, window === self.owner else { return }
      self.owner = nil
      self.panel.close()
    })
  }

  deinit { observers.forEach(NotificationCenter.default.removeObserver) }

  private func kind(for window: NSWindow) -> MediaInfoKind? {
    if window.windowController is ImageViewerWindowController { return .image }
    if window.windowController is PlayerWindowController { return .video }
    return nil
  }

  private func url(for window: NSWindow) -> URL? {
    if let image = window.windowController as? ImageViewerWindowController { return image.selectedURL }
    guard let player = (window.windowController as? PlayerWindowController)?.player,
          player.info.state.active, let url = player.info.currentURL, url.isFileURL else { return nil }
    return url
  }

  func candidate(sender: Any? = nil, keyWindow: NSWindow?, mainWindow: NSWindow?) -> NSWindow? {
    if let view = sender as? NSView, let window = view.window, kind(for: window) != nil { return window }
    if let key = keyWindow {
      if key.sheetParent != nil { return nil }
      if kind(for: key) != nil { return key }
      if panel.isWindowLoaded, key === panel.window { return owner }
      return nil
    }
    guard let main = mainWindow, kind(for: main) != nil, main.attachedSheet == nil else { return nil }
    return main
  }

  @objc func showMediaInfo(_ sender: Any?) {
    guard let window = candidate(sender: sender, keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow), window.attachedSheet == nil,
          let kind = kind(for: window), let url = url(for: window) else { return }
    owner = window
    panel.present(url: url, kind: kind, relativeTo: window)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let window = candidate(keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow), window.attachedSheet == nil else { return false }
    return url(for: window) != nil
  }

  private func sourceChanged(_ note: Notification) {
    guard let owner else { return }
    if let image = owner.windowController as? ImageViewerWindowController,
       note.object as AnyObject? === image {
      refreshOwner()
    } else if let video = owner.windowController as? PlayerWindowController,
              note.object as AnyObject? === video.player {
      refreshOwner()
    }
  }

  private func refreshOwner() {
    guard let owner, let kind = kind(for: owner) else { return }
    panel.sourceDidChange(url: url(for: owner), kind: kind)
  }

  func close() {
    owner = nil
    panel.close()
  }
}
