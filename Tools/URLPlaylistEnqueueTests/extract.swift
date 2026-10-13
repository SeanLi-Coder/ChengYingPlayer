import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let core = try String(contentsOf: root.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)
let app = try String(contentsOf: root.appendingPathComponent("iina/AppDelegate.swift"), encoding: .utf8)
func span(_ start: String, _ end: String) -> String {
  precondition(core.components(separatedBy: start).count == 2, "Ambiguous source start")
  let a = core.range(of: start)!.lowerBound
  let b = core.range(of: end, range: a..<core.endIndex)!.lowerBound
  return String(core[a..<b])
}
func method(_ signature: String) -> String {
  precondition(core.components(separatedBy: signature).count == 2, "Ambiguous method")
  let a = core.range(of: signature)!.lowerBound
  let b = core.range(of: "\n  }", range: a..<core.endIndex)!.upperBound
  return String(core[a..<b])
}
var members = span("  private var permanentRotationIntent", "  var touchBarSupport:")
members += span("  private struct NativeCompatibilityRestore", "  private var playbackTransport:")
members += span("  private struct URLPlaylistRequest", "  func appendToPlaylist(")
members += try String(contentsOf: root.appendingPathComponent("Tools/NativePlayerCoreTests/NoNativeQueueBoundary.txt"), encoding: .utf8)
  .replacingOccurrences(of: "__PRODUCTION_QUEUE_INSTALLATION_DECLARATIONS__",
    with: span("  private final class NativeQueueInstallation {", "  var hasNativePlaybackQueue:"))
for signature in ["  func requireMPVCompatibility(", "  private func retireNativePlayback(",
                  "  private func projectNativeWindowOptionsToMPV(",
                  "  private func open(_ url:", "  func stop()", "  func shutdown()",
                  "  func seek(absoluteSecond:", "  func seek(relativeSecond:", "  func seek(percent:",
                  "  var nativeInitialPlaybackPending:", "  var playbackIsPaused:",
                  "  func pause()", "  func resume()", "  func togglePause(", "  func fileEnded("] {
  members += "\n" + method(signature)
}
let opening = method("  private func openMainWindow(")
let boundary = "\n    log(\"Opening "
precondition(opening.components(separatedBy: boundary).count == 2)
members += "\n" + String(opening[..<opening.range(of: boundary)!.lowerBound]) +
  "\n    completeLegacyOpen(url: url, allowNative: allowNative)\n  }\n"
members += "\n  func fileLoadedBoundary() {\n" + span(
  "    if var restore = nativeCompatibilityRestore, restore.url == info.currentURL {", "\n  func fileEnded(")
members += "\n  func restartBoundary() {\n" + span(
  "    if let restore = nativeCompatibilityRestore, restore.waitingForSeek,", "\n  func refreshEdrMode()")
let started = method("  func fileStarted(path: String)")
func startedSpan(_ start: String, _ end: String) -> String {
  precondition(started.components(separatedBy: start).count == 2, "Ambiguous file-start receipt")
  let a = started.range(of: start)!.lowerBound
  let b = started.range(of: end, range: a..<started.endIndex)!.lowerBound
  return String(started[a..<b])
}
// The URL/load service is controlled by the fixture. Preserve the production
// media-generation and generic-owner receipt transition before the URL receipt.
members += "\n  func fileStartedReceiptBoundary() {\n" +
  startedSpan("    let genericReceipt =", "    log(") +
  startedSpan("    videoToolsMediaGeneration &+= 1", "    videoToolsClearLoop()") +
  startedSpan("    if let id = genericReceipt,", "    let ownedRotationReload =") + "  }\n"
let mutation = ProcessInfo.processInfo.environment["URL_ENQUEUE_NEGATIVE"] ?? ""
let enqueueBegin = app.range(of: "      // enqueue\n")!.upperBound
let enqueueEnd = app.range(of: "      // presentation options", range: enqueueBegin..<app.endIndex)!.lowerBound
var dispatch = String(app[enqueueBegin..<enqueueEnd])
let playlistRead = "(enqueueRecipient ?? PlayerCore.lastActive).info.$playlist.withLock { $0.isEmpty }"
precondition(dispatch.components(separatedBy: playlistRead).count == 2)
// Only the playlist-read service is controlled. The actual URL enqueue/open
// branch and notification/OSD callback are otherwise compiled verbatim.
dispatch = dispatch.replacingOccurrences(of: playlistRead, with: "fixturePlaylistEmpty")
let osdMethod = method("  func sendOSD(")
let osdBody = osdMethod.range(of: "    DispatchQueue.main.async {")!.lowerBound
let osdSignature = String(osdMethod[..<osdMethod.firstIndex(of: "\n")!])
var osd = osdSignature + "\n" + osdMethod[osdBody...]
let optionGuard = app.range(of: "!enqueueRecipient.validateURLPlaylistEnqueueOptions(Set(queryDict.keys))")!.lowerBound
precondition(optionGuard < app.range(of: "      let imagePlan: ImageOpenPlan?", range: optionGuard..<app.endIndex)!.lowerBound)
precondition(optionGuard < app.range(of: "      // new_window", range: optionGuard..<app.endIndex)!.lowerBound)
func replaceOnce(_ old: String, _ new: String) {
  precondition(members.components(separatedBy: old).count == 2, "Negative landmark changed")
  members = members.replacingOccurrences(of: old, with: new)
}
switch mutation {
case "": break
case "early-append":
  replaceOnce("    urlPlaylistBatch = batch\n    let timeout = Timer", "    urlPlaylistBatch = batch\n    mpv.command(.loadfile, args: [paths[0], \"append\"], checkError: false, level: .verbose) { _ in }\n    let timeout = Timer")
case "drop-owner":
  replaceOnce("    cancelURLPlaylistEnqueue()\n    urlPlaylistMediaEpoch = UUID()",
              "    /* negative: abandon reset ownership */\n    urlPlaylistMediaEpoch = UUID()")
case "drop-pause-restore":
  replaceOnce("           hasPendingURLPlaylistRestore || hasPendingNativeQueueRestore || hasPendingGenericPlaybackRestore)",
              "           false || hasPendingNativeQueueRestore || hasPendingGenericPlaybackRestore)")
case "ignore-result":
  replaceOnce("        if $0 >= 0 { count += 1 }", "        _ = $0; count += 1")
case "empty-playlist":
  let condition = "!playlistEmpty || enqueueRecipient?.hasPendingURLPlaylistEnqueue == true"
  precondition(dispatch.components(separatedBy: condition).count == 2)
  dispatch = dispatch.replacingOccurrences(of: condition, with: "!playlistEmpty")
case "unguarded-osd":
  let guardLine = "      guard stillApplies?() ?? true else { return }\n"
  precondition(osd.components(separatedBy: guardLine).count == 2)
  osd = osd.replacingOccurrences(of: guardLine, with: "")
case "stale-tail-receipt":
  replaceOnce("request.completion(batch.epoch == urlPlaylistMediaEpoch ? count : 0)", "request.completion(count)")
case "stale-file-start":
  replaceOnce("    if !ownedURLPlaylistReload { resetURLPlaylistEnqueue() }",
              "    _ = ownedURLPlaylistReload")
case "missing-generic-start":
  replaceOnce(startedSpan("    if let id = genericReceipt,", "    let ownedURLPlaylistReload ="),
              "    _ = genericReceipt\n")
default: fatalError("Unknown negative control")
}
let bridge = try String(contentsOf: root.appendingPathComponent("iina/VideoTools/VideoToolsPlayerBridge.swift"), encoding: .utf8)
let a = bridge.range(of: "struct VideoToolsViewport:")!.lowerBound
let b = bridge.range(of: "struct VideoToolsPlayerSnapshot")!.lowerBound
let result = """
import Cocoa
\(bridge[a..<b])
final class PlayerCore: CoreBoundary {
\(members.replacingOccurrences(of: "private ", with: ""))
\(osd)
  var testNotificationHook: (() -> Void)?
  var displayedOSDs = 0
  var urlFallbackOpens = 0
  override func postNotification(_ name: NotificationName) {
    super.postNotification(name)
    testNotificationHook?()
  }
}
func dispatchURLPlaylistBranch(queryDict: [String: String], player: PlayerCore,
  enqueueRecipient: PlayerCore?, imagePlan: FixtureImagePlan? = nil, fixturePlaylistEmpty: Bool) {
  let urlValue = queryDict["url"]!
\(dispatch)
}
// Rotation UI is outside this non-window fixture. Enqueue rejects that owner.
final class QuickSetting: QuickSettingBoundary {
  func cancelPendingAutomaticVideoToolsPreview() { fatalError("Unexpected rotation UI") }
  func applyPermanentRotation(clockwiseQuarterTurns: Int, inputURL: URL) -> Bool { fatalError("Unexpected rotation delivery") }
}
final class Panel: PanelBoundary {}
"""
try result.write(to: output, atomically: true, encoding: .utf8)
