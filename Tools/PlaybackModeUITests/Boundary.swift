import Cocoa

final class PlaybackModeCanvas: NSView {
  override var isOpaque: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
  }
}

// An in-memory playback boundary keeps UI tests away from mpv and user defaults.
final class PlayerCore {
  var mode: LoopMode = .off
  var selectedModes: [LoopMode] = []
  func getLoopMode() -> LoopMode { mode }
  func setLoopMode(_ mode: LoopMode) {
    self.mode = mode
    selectedModes.append(mode)
  }
  func toggleFileLoop() { setLoopMode(mode == .file ? .off : .file) }
  func togglePlaylistLoop() { setLoopMode(mode == .playlist ? .off : .playlist) }
}
