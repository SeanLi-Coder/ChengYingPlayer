import AppKit

// Only app services and the compatibility coordinator are boundaries. The
// complete production drop method and the private AppKit pasteboard are real.
final class PlayerCore {
  var isUsingNativePlayback = true
  var openResult: Int? = 0
  var filterResult = true
  var openRequests: [[URL]] = []
  var stringRequests: [String] = []
  var filters: [MPVFilter] = []
  var subtitles: [URL] = []
  var messages: [OSDMessage] = []
  var unsafeCommands = 0
  var pending: [(reason: String, action: () -> Void)] = []

  func requireMPVCompatibility(reason: String, completion: @escaping () -> Void) {
    pending.append((reason, completion))
  }
  func finishCompatibility() {
    isUsingNativePlayback = false
    let callbacks = pending
    pending.removeAll()
    callbacks.forEach { $0.action() }
  }
  func cancelCompatibility() { pending.removeAll() }
  func openURLs(_ urls: [URL]) -> Int? { openRequests.append(urls); return openResult }
  func openURLString(_ string: String) { stringRequests.append(string) }
  func addVideoFilter(_ filter: MPVFilter) -> Bool {
    if isUsingNativePlayback { unsafeCommands += 1 }
    filters.append(filter)
    return filterResult
  }
  func loadExternalSubFile(_ url: URL) {
    if isUsingNativePlayback { unsafeCommands += 1 }
    subtitles.append(url)
  }
  func sendOSD(_ message: OSDMessage) { messages.append(message) }
}
struct MPVFilter {
  let lavfiName: String
  let label: String
  let paramDict: [String: String]
}
enum OSDMessage: Equatable { case addFilter(String) }
enum Utility {
  enum ExtensionType { case sub }
  static let lut3dExt = ["cube", "3dl"]
  static let supportedFileExt: [ExtensionType: [String]] = [.sub: ["srt", "ass"]]
  static var resolvedPrefix = ""
  static var alerts: [String] = []
  static func resolvePaths(_ paths: [String]) -> [String] {
    paths.map { resolvedPrefix + $0 }
  }
  static func showAlert(_ name: String) { alerts.append(name) }
}
struct Regex {
  let prefix: String
  static let url = Self(prefix: "https://")
  static let filePath = Self(prefix: "/")
  func matches(_ value: String) -> Bool { value.hasPrefix(prefix) }
}
extension String {
  var lowercasedPathExtension: String { (self as NSString).pathExtension.lowercased() }
}
extension NSPasteboard.PasteboardType {
  static let nsFilenames = Self("NSFilenamesPboardType")
  static let nsURL = Self("NSURLPboardType")
}

final class DragInfo: NSObject, NSDraggingInfo {
  let draggingPasteboard: NSPasteboard
  init(_ board: NSPasteboard) { draggingPasteboard = board }
  var draggingDestinationWindow: NSWindow? { nil }
  var draggingSourceOperationMask: NSDragOperation { .copy }
  var draggingLocation: NSPoint { .zero }
  var draggedImageLocation: NSPoint { .zero }
  var draggedImage: NSImage? { nil }
  var draggingSource: Any? { nil }
  var draggingSequenceNumber: Int { 1 }
  var draggingFormation = NSDraggingFormation.none
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 0
  var springLoadingHighlight = NSSpringLoadingHighlight.none
  func slideDraggedImage(to screenPoint: NSPoint) {}
  override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
  func resetSpringLoading() {}
  func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
