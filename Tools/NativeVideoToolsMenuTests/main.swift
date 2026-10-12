import AppKit

// The menu and media predicates are extracted verbatim. Window attachment is
// only a recording boundary; the real nib and preview remain a full-App test.
struct TrackBoundary { var isAlbumart = false }
final class InfoBoundary {
  var state = PlayerState.paused
  var isNetworkResource = false
  var currentURL: URL?
  var videoTracks: [TrackBoundary] = []
  var audioTracks: [TrackBoundary] = []
}
final class WindowBoundary { var isVisible = true }
final class MainWindowBoundary {
  enum Tab { case tools }
  var loaded = true
  var window: WindowBoundary? = WindowBoundary()
  var isInInteractiveMode = false
  var toolsRequests = 0
  func showSettingsSidebar(tab: Tab) {
    precondition(tab == .tools)
    toolsRequests += 1
  }
}
struct MediaBoundary { var hasVideo = true }
final class PlayerBoundary {
  let info = InfoBoundary()
  let mainWindow = MainWindowBoundary()
  var nativeTransport: NSObject? = NSObject()
  var nativeRetiring = false
  var nativeTerminationRequested = false
  var nativeReady = true
  var nativePlaybackMedia: MediaBoundary? = MediaBoundary()
  var isInMiniPlayer = false
  var isUsingNativePlayback: Bool { nativeTransport != nil }
}

setbuf(stdout, nil)
_ = NSApplication.shared
let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
var checks = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
  checks += 1
  if !condition() { failures += 1; print("FAIL: \(label)") }
}

func verify(_ label: String, native: Bool = true, accepted: Bool,
            mutate: (PlayerBoundary) -> Void = { _ in }) {
  let player = PlayerBoundary()
  player.info.currentURL = fixture
  if !native {
    player.nativeTransport = nil
    player.info.videoTracks = [TrackBoundary()]
  }
  mutate(player)
  let handler = MenuUnderTest(player)
  let item = NSMenuItem(title: "Synthetic tools action", action: #selector(MenuUnderTest.menuShowVideoTools(_:)), keyEquivalent: "")
  check(handler.validateMenuItem(item) == accepted, "\(label): actual menu validation")
  // sendAction succeeds even when an action's internal guard rejects it. Both
  // dispatch and actual sidebar requests must therefore be checked separately.
  check(NSApp.sendAction(item.action!, to: handler, from: item), "\(label): actual AppKit dispatch")
  check(player.mainWindow.toolsRequests == (accepted ? 1 : 0), "\(label): sidebar request count")
  if native { check(player.info.videoTracks.isEmpty && player.info.audioTracks.isEmpty,
                    "\(label): no synthetic MPV tracks") }
}

let empty = InfoBoundary()
check(empty.isAudio == .unknown, "Real PlaybackInfo classifies empty MPV tracks as unknown")
verify("Admitted native video with empty MPV tracks", accepted: true)
verify("Admitted native playing video", accepted: true) { $0.info.state = .playing }
verify("Native metadata absent", accepted: false) { $0.nativePlaybackMedia = nil }
verify("Native audio-only metadata", accepted: false) { $0.nativePlaybackMedia?.hasVideo = false }
verify("Native admission not completed", accepted: false) { $0.nativeReady = false }
verify("Native initial UI setup not completed", accepted: false) { $0.info.state = .loaded }
for state: PlayerState in [.loading, .starting, .stopping, .idle, .shuttingDown, .shutDown] {
  verify("Native state \(state)", accepted: false) { $0.info.state = state }
}
let commonRejections: [(String, (PlayerBoundary) -> Void)] = [
  ("Mini player", { $0.isInMiniPlayer = true }),
  ("Window not loaded", { $0.mainWindow.loaded = false }),
  ("Window absent", { $0.mainWindow.window = nil }),
  ("Window hidden", { $0.mainWindow.window?.isVisible = false }),
  ("Interactive mode", { $0.mainWindow.isInInteractiveMode = true }),
  ("Network flag", { $0.info.isNetworkResource = true }),
  ("Remote URL", { $0.info.currentURL = URL(string: "https://example.invalid/synthetic.mp4") }),
  ("No source URL", { $0.info.currentURL = nil }),
  ("Missing local file", { $0.info.currentURL = fixture.appendingPathExtension("missing") }),
]
for (name, mutation) in commonRejections {
  verify("Native \(name)", accepted: false, mutate: mutation)
  verify("Legacy \(name)", native: false, accepted: false, mutate: mutation)
}
verify("Legacy regular video", native: false, accepted: true)
verify("Legacy loaded video", native: false, accepted: true) { $0.info.state = .loaded }
verify("Legacy playing video", native: false, accepted: true) { $0.info.state = .playing }
verify("Legacy empty tracks", native: false, accepted: false) { $0.info.videoTracks = [] }
verify("Legacy audio-only tracks", native: false, accepted: false) {
  $0.info.videoTracks = []; $0.info.audioTracks = [TrackBoundary()]
}
verify("Legacy album art", native: false, accepted: false) {
  $0.info.videoTracks = [TrackBoundary(isAlbumart: true)]; $0.info.audioTracks = [TrackBoundary()]
}
verify("Legacy video plus album art", native: false, accepted: true) {
  $0.info.videoTracks = [TrackBoundary(isAlbumart: true), TrackBoundary()]
}
for state: PlayerState in [.loading, .starting, .stopping, .idle, .shuttingDown, .shutDown] {
  verify("Legacy state \(state)", native: false, accepted: false) { $0.info.state = state }
}
print("Tools menu checks: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
