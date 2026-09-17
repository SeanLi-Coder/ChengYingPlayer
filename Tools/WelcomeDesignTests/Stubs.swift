import Cocoa

final class PlayerCore {
  var opened: [URL] = []
  func openURL(_ url: URL) { opened.append(url) }
  func acceptFromPasteboard(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
  func openFromPasteboard(_ sender: NSDraggingInfo) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  static let shared = AppDelegate()
  var openedFilePanels = 0
  var openedDownloadCenters = 0
  var openedFileAccessGuides = 0
  func openFile(_ sender: Any?) { openedFilePanels += 1 }
  @objc func menuShowDownloadCenter(_ sender: Any?) { openedDownloadCenters += 1 }
  @objc func showFileAccessGuide(_ sender: Any?) { openedFileAccessGuides += 1 }
}

// Shadow the AppKit boundary so a regression can never inspect the user's real history.
final class NSDocumentController {
  static var shared: NSDocumentController { fatalError("Welcome must not access document history") }
  var recentDocumentURLs: [URL] { fatalError("Welcome must not read recent document URLs") }
}

enum Preference {
  enum Key: String {
    case themeMaterial, recordRecentFiles, resumeLastPosition
    case iinaLastPlayedFilePath, iinaLastPlayedFilePosition
  }
  enum Theme: Int { case dark, light, system }
  static var values: [Key: Any] = [.recordRecentFiles: true, .resumeLastPosition: true]
  static var reads: [Key] = []
  static func bool(for key: Key) -> Bool { reads.append(key); return values[key] as? Bool ?? false }
  static func url(for key: Key) -> URL? { reads.append(key); return values[key] as? URL }
  static func double(for key: Key) -> Double { reads.append(key); return values[key] as? Double ?? 0 }
  static func `enum`(for key: Key) -> Theme { reads.append(key); return values[key] as? Theme ?? .dark }
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
  static let keyMap: [UInt16: (String, String)] = [36: ("ENTER", ""), 76: ("KP_ENTER", ""),
                                               125: ("DOWN", ""), 126: ("UP", "")]
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
  override func loadWindow() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.contentView = InitialWindowContentView()
    self.window = window
  }
}
