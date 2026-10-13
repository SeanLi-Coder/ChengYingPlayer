import Cocoa

// Reuse the controlled capture/shutdown/MPV-load service boundaries from the
// rotation handoff tests. All enqueue/restore/arbitration methods are extracted
// verbatim. This is not a real MPV, rendering, URL dispatch or AppKit test.
private let enqueueMutationLock = NSRecursiveLock()
extension CoreBoundary {
  var playlistMutationLock: NSRecursiveLock { enqueueMutationLock }
}
extension Utility {
  static func isLocalPlaybackPath(_ path: String) -> Bool {
    path.hasPrefix("/") && !path.hasSuffix(".png")
  }
}
extension MockMPV {
  func command(_ value: MPVCommand, args: [String?], checkError: Bool,
               level: Logger.Level, returnValueCallback: (Int32) -> Void) {
    precondition(value == .loadfile && args.count == 2 && args[1] == "append" && !checkError)
    let path = args[0]!
    if path.contains("no-callback") { return }
    if path.contains("reject") { returnValueCallback(-1); return }
    commands.append("append:" + path)
    returnValueCallback(0)
  }
}
