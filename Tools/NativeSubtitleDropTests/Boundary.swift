// App/image UI and drag metadata are boundaries; the pasteboard and every
// admission/drop/subtitle method, decoder, Session and libmpv result are real.
struct MPVTrack { let id: Int; let externalFilename: String? }
struct FilterPresetInstance {
  struct Preset { let name: String }
  var params: [String: NSNumber] { preconditionFailure("Preset UI is outside drop routing") }
  var preset: Preset { preconditionFailure("Preset UI is outside drop routing") }
}
extension Logger { static func log(_ text: String, level: Level = .debug) {} }
extension Preference {
  enum HardwareDecoderOption: Int { case disabled, autoCopy }
  static func set(_ value: Int, for key: Key) { preconditionFailure("Real MPV uses hwdec=no; no modal preference changes") }
}
final class ImageViewerCoordinator {
  static let shared = ImageViewerCoordinator()
  func openImages(in urls: [URL]) -> ImageOpenPlan {
    let plan = ImageOpenPlan.make(urls, playbackExtensions: Set(Utility.playableFileExt))
    precondition(!plan.hasImageViewerInput, "Image-window presentation is outside this fixture")
    return plan
  }
}
extension PlayerCore {
  func openURLString(_ value: String) { preconditionFailure("Only file-list drops belong to this fixture") }
}
extension MPVController {
  func command(_ name: MPVCommand, args: [String], checkError: Bool, level: Logger.Level = .debug,
               callback: (Int32) -> Void) {
    callback(queueCommand([name.rawValue] + args)!)
  }
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
