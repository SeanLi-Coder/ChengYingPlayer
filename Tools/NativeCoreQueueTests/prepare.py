#!/usr/bin/env python3
"""Extract production Core queue methods; UI/application services stay explicit boundaries."""
from pathlib import Path
import os
import sys

root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1])
core = (root / "iina/PlayerCore.swift").read_text()

def method(signature):
    start = core.index(signature)
    return core[start:core.index("\n  }", start) + 4]

def section(start, end):
    offset = core.index(start)
    return core[offset:core.index(end, offset)]

declarations = section("  private var nativeTransport:", "  var receivedEndFileWhileLoading:")
declarations += section("  private var permanentRotationIntent", "\n  /// Both window shortcuts")
queue = section("  // A fixed explicit selection", "  /// This opt-in route deliberately")
methods = [
    "  func captureMPVEventRevision()", "  func acceptsMPVEventRevision(", "  func noteMPVMediaCommand()",
    "  private func attemptNativeOpen(", "  private func beginNativeOpen(", "  private func receiveNativeSnapshot(",
    "  func requireMPVCompatibility(", "  private func retireNativePlayback(", "  private func open(_",
    "  private func openMainWindow(", "  func initVideo()", "  func shutdown()", "  func stop()", "  func idleActiveChanged()",
    "  func notifyWindowVideoSizeChanged()", "  func getMediaTitle(", "  func syncAbLoop()",
    "  func pause()", "  func resume()", "  func togglePause(", "  func setVolume(", "  func setSpeed(",
    "  @discardableResult\n  func syncVolumeFromMPV()", "  func speedChanged(",
    "  @discardableResult\n  func requestPermanentRotation(", "  private func deliverPermanentRotation(",
    "  @discardableResult\n  func cancelPendingPermanentRotation(", "  private func resetPermanentRotationMedia(",
    "  private var pendingRotationPlaybackRestore:", "  @discardableResult\n  private func updatePendingRotationRestore(",
    "  private func updatePendingPlaybackVolume(", "  private func updatePendingPlaybackSpeed(",
    "  private func ownsPermanentRotationRequest(", "  func openMediaURLs(",
    "  func playFileInPlaylist(", "  func navigateInPlaylist(", "  private func applyLoopMode(",
    "  func appendToPlaylist(", "  func playlistMove(", "  func addToPlaylist(", "  func playlistRemove(_ index: Int)",
    "  func clearPlaylist()", "  func toggleShuffle()",
    "  func seek(percent:", "  func seek(relativeSecond:", "  func seek(absoluteSecond:",
    "  func fileStarted(", "  func fileLoaded()", "  func playbackRestarted()", "  func onVideoReconfig()",
]
bridge = (root / "iina/VideoTools/VideoToolsPlayerBridge.swift").read_text()
viewport = bridge[bridge.index("struct VideoToolsViewport:"):bridge.index("struct VideoToolsPlayerSnapshot")]
boundary = (root / "Tools/NativePlayerRouteTests/PlayerBoundary.txt").read_text()
boundary = boundary.replace("private let mpvPlaybackTransport: PlaybackTransport = CompatibilityTransportDouble()",
                            "private lazy var mpvPlaybackTransport: PlaybackTransport = makeMPVTransport()")
boundary = boundary.replace('  func seek(absoluteSecond: Double) { fatalError("EOF replay is outside initial admission tests") }\n', '')
boundary = boundary.replace("  private let playlistMutationLock", "  let playlistMutationLock")
boundary = boundary.replace("  private var backgroundTaskInUse = false\n", "")
boundary = boundary.replace("enum AudioStatus { case notAudio }", "enum AudioStatus { case notAudio, unknown }")
boundary += "\n  @Atomic var backgroundQueueTicket = 0\n  var backgroundTaskTickets = Set<Int>()\n  var triedUsingExactSeekForCurrentFile = false\n  var useExactSeekForCurrentFile = true\n  var receivedEndFileWhileLoading = false\n  var currentWindow: NSWindow? { mainWindow.window }\n"
boundary = boundary.replace("  func videoToolsEnforceLoopBounds() {}", "  func videoToolsEnforceLoopBounds(playbackRestarted: Bool = false) {}")
boundary = boundary.replace("  func postNotification(_ name: Notification.Name) { notifications.append(name) }",
                            "  func postNotification(_ name: Notification.Name) { notifications.append(name); notificationHook?(name) }")
boundary = boundary.replace("  func savePlayerState() {}", "  func savePlayerState() {}\n  var notificationHook: ((Notification.Name) -> Void)?")
no_enqueue = (root / "Tools/NativePlayerCoreTests/NoURLPlaylistBoundary.txt").read_text()
info = (root / "iina/PlaybackInfo.swift").read_text()
state = info[info.index("  var state: PlayerState = .idle {"):info.index("\n  var isSeeking:")]
output = "import AppKit\nimport AVFoundation\n" + viewport + "\nfinal class PlayerCore {\n"
output += boundary + declarations + no_enqueue + queue + "\n".join(map(method, methods)) + "\n}\n"
output += "final class PlaybackInfoDouble: PlaybackInfoFields { unowned let player: PlayerCore; init(player: PlayerCore) { self.player = player; super.init() }\n" + state + "\n}\n"
# Tests inspect ownership without changing the production function bodies.
output = output.replace("private ", "")
negative = os.environ.get("NATIVE_QUEUE_NEGATIVE_CONTROL", "")
replacements = {
    "deduplicate-plan": ("NativeQueuePlan(urls: urls)", "NativeQueuePlan(urls: playableFiles)"),
    "forget-eof-seek": ("if nativeQueue?.acceptedSeek(token) == true {", "if false {"),
    "old-draining-toggle": ("(nativeTransport == nil || nativeRetiring)", "nativeTransport == nil"),
    "wrong-reopen-count": ("return explicitNativePlan?.items.count ?? count", "return count"),
    "forget-eof-marker-seek": (
        "recordNativeQueueSeek(transport.seek(.init(value: range.start, reference: .absoluteSeconds, exact: true)))",
        "transport.seek(.init(value: range.start, reference: .absoluteSeconds, exact: true))"),
    "preview-pause-persistent": (
        "if nativePreviewBaseline == nil { _ = nativeQueue?.setIntent(.paused) }",
        "_ = nativeQueue?.setIntent(.paused)"),
    "preview-resume-persistent": (
        "if nativePreviewBaseline == nil,\n       let decision = nativeQueue?.setIntent(.playing), case .rewind = decision {",
        "if let decision = nativeQueue?.setIntent(.playing), case .rewind = decision {"),
    "preview-pending-intent": (
        "if nativePreviewBaseline == nil { _ = nativeQueue?.setIntent(.paused) }",
        "if !nativePreviewInProgress { _ = nativeQueue?.setIntent(.paused) }"),
    "preview-cancel-intent": (
        "_ = nativeQueue?.setIntent(playbackTransport.isPaused ? .paused : .playing)",
        "_ = playbackTransport.isPaused"),
    "auto-next-ignores-open-preference": (
        "_ = nativeQueue?.setIntent(Preference.bool(for: .pauseWhenOpen) ? .paused : .playing)",
        "if manual { _ = nativeQueue?.setIntent(Preference.bool(for: .pauseWhenOpen) ? .paused : .playing) }"),
    "rewind-reopens-session": (
        "    case .rewind(let request):\n", "    case .rewind(let request):\n      applyNativeQueueDecision(.load(request), manual: manual); return\n"),
    "consume-stop-owner": (
        "      mpv.stopCancelledNativeQueue(owner: owner)",
        "      pendingNativeQueueStopOwner = nil\n      mpv.stopCancelledNativeQueue(owner: owner)"),
    "missing-stop-prepare": (
        "      mpv.prepareCancelledNativeQueueStop(owner: owner)", "      _ = owner"),
    "stale-auto-advance-preference": (
        "nativeQueue?.setAutoAdvance(Preference.bool(for: .playlistAutoPlayNext))",
        "_ = Preference.bool(for: .playlistAutoPlayNext)"),
    "forget-pending-volume": ("restore.volume = volume", "_ = volume"),
    "forget-pending-speed": ("restore.rate = speed", "_ = speed"),
    "forget-verified-audio-intent": (
        "      // User actions during loading or the exact seek supersede the original\n"
        "      // capture. Apply them only after this same-media restoration is verified.\n"
        "      playbackTransport.setRate(restore.rate)\n      playbackTransport.setVolumePercent(restore.volume)\n",
        "      // Negative control: retain the values applied before the exact seek.\n"),
}
if negative and negative != "stale-seek-eof":
    if negative not in replacements:
        raise SystemExit("Unknown negative control")
    before, after = replacements[negative]
    if output.count(before) != 1:
        raise SystemExit("Negative-control landmark is not unique")
    output = output.replace(before, after, 1)
(out / "Core.swift").write_text(output)
transport = (root / "iina/PlaybackBackend/NativePlaybackTransport.swift").read_text()
if negative == "stale-seek-eof":
    before = "return pendingSeek == nil && snapshot?.phase == .ended"
    if transport.count(before) != 1:
        raise SystemExit("EOF negative-control landmark is not unique")
    transport = transport.replace(before, "return snapshot?.phase == .ended", 1)
(out / "Transport.swift").write_text(transport)

services = (root / "Tools/NativePlayerRouteTests/Boundary.swift").read_text()
start = services.index("final class MPVController {")
end = services.index("final class ViewLayer:", start)
services = services[:start] + services[end:]
services = services.replace("struct MPVPlaylistItem { let filename: String; let isCurrent: Bool; let isPlaying: Bool; let title: String? }", "")
services = services.replace("enum LoopMode { case off, file, playlist }", "")
services = services.replace("func showWindow(_ sender: Any?) { showCount += 1; window?.orderFront(nil) }",
                            "func showWindow(_ sender: Any?) { showCount += 1 }")
services = services.replace("enum OSDMessage { case custom(String) }", "enum OSDMessage { case custom(String), addToPlaylist(Int), speed(Double) }")
services = services.replace("enum Key {", "enum Key { case useExactSeek, recordRecentFiles, trackAllFilesInRecentOpenMenu, maxVolume, softVolume\n")
services = services.replace("static func integer(for key: Key) -> Int { 0 }", "static func integer(for key: Key) -> Int { key == .maxVolume ? 100 : 0 }")
services = services.replace("enum Name { case fileLoaded, mpvInitialized }", "enum Name { case fileLoaded, mpvInitialized, fileStarted }")
services = services.replace("  static func savedLoopMode(in defaults: UserDefaults, domain: String?) -> LoopMode? { .off }",
                            "  static var loopMode: LoopMode = .off\n  static func savedLoopMode(in defaults: UserDefaults, domain: String?) -> LoopMode? { loopMode }")
(out / "Services.swift").write_text(services)
