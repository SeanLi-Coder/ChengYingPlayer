import Cocoa

final class PlayerCore {
  var opened: [URL] = []
  func openURL(_ url: URL) { opened.append(url) }
  func acceptFromPasteboard(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
  func openFromPasteboard(_ sender: NSDraggingInfo) -> Bool { true }
}

final class AppDelegate {
  static let shared = AppDelegate()
  var openedFilePanel = false
  func openFile(_ sender: Any?) { openedFilePanel = true }
}

enum Preference {
  enum Key: String {
    case themeMaterial, recordRecentFiles, resumeLastPosition
    case iinaLastPlayedFilePath, iinaLastPlayedFilePosition
  }
  enum Theme: Int { case dark, light, system }
  static var values: [Key: Any] = [.recordRecentFiles: true, .resumeLastPosition: true]
  static func bool(for key: Key) -> Bool { values[key] as? Bool ?? false }
  static func url(for key: Key) -> URL? { values[key] as? URL }
  static func double(for key: Key) -> Double { values[key] as? Double ?? 0 }
  static func `enum`(for key: Key) -> Theme { .dark }
}

struct InfoDictionary {
  enum BuildType { case release; var description: String { "RELEASE" } }
  static let shared = InfoDictionary()
  let version = ("0.1.6", "7")
  let buildType = BuildType.release
}

struct VideoTime {
  let value: Double
  init(_ value: Double) { self.value = value }
  var stringRepresentation: String {
    String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60)
  }
}

enum KeyCodeHelper {
  static let keyMap: [UInt16: (String, String)] = [36: ("ENTER", ""), 125: ("DOWN", ""), 126: ("UP", "")]
}

extension Array {
  subscript(at index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension NSPasteboard.PasteboardType {
  static let nsURL = NSPasteboard.PasteboardType("NSURL")
  static let nsFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
}

extension NSAppearance {
  convenience init?(iinaTheme theme: Preference.Theme) {
    self.init(named: theme == .dark ? .darkAqua : .aqua)
  }
}

final class WelcomeHarness: InitialWindowController {
  override func reloadData() {
    precondition(Thread.isMainThread, "Welcome UI updates must run on the main thread")
    super.reloadData()
  }

  override func loadWindow() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.contentView = InitialWindowContentView()
    self.window = window
  }
}
