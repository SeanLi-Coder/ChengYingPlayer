#if CHENGYING_NATIVE_APP_TESTS
import AppKit
import AVFoundation
import CoreVideo

/// Compiled only into the disposable CI application, never the release executable.
/// All player, controller, nib and rendering objects below are production objects.
final class NativeAppTestDriver {
  private static var instance: NativeAppTestDriver?
  private static let fixtureNames = ["red/red.mp4", "blue/blue.mp4", "compat/compat.mp4"]
  private let root: URL
  private let runID: String
  private let pixelReferences: [String: [Int]]
  private var checks: [[String: Any]] = []
  private var observer: NSObjectProtocol?
  private var terminal = false
  private var awaitingQuit = false
  private var pollRevision = 0
  private var player: PlayerCore?

  private init(root: URL, runID: String, pixelReferences: [String: [Int]]) {
    self.root = root
    self.runID = runID
    self.pixelReferences = pixelReferences
  }

  static func prepareForLaunch() {
    dispatchPrecondition(condition: .onQueue(.main))
    let environment = ProcessInfo.processInfo.environment
    guard environment["CI"] == "true",
          environment["GITHUB_ACTIONS"] == "true",
          environment["RUNNER_ENVIRONMENT"] == "github-hosted",
          environment["CHENGYING_NATIVE_PLAYBACK"] == "1",
          let runID = environment["CHENGYING_NATIVE_APP_TEST_RUN_ID"],
          let uuid = UUID(uuidString: runID),
          let directory = environment["CHENGYING_NATIVE_APP_TEST_ROOT"],
          directory.hasPrefix("/"),
          Bundle.main.bundleIdentifier == "io.chengying.tests.native-app." + uuid.uuidString.lowercased().replacingOccurrences(of: "-", with: "") else {
      preflightFailure()
    }
    let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
    let manager = FileManager.default
    guard root.resolvingSymlinksInPath().path == root.path,
          root.pathComponents.count > 3,
          let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
          rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
          hasOwnedWorkspace(above: root) else { preflightFailure() }
    let marker = root.appendingPathComponent("native-app-fixture.json")
    guard marker.resolvingSymlinksInPath().path == marker.path,
          let data = try? Data(contentsOf: marker), data.count < 4096,
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          payload["format"] as? Int == 1,
          payload["run_id"] as? String == runID,
          payload["fixtures"] as? [String] == fixtureNames,
          let references = payload["pixel_references"] as? [String: [Int]],
          Set(references.keys) == Set(["red", "green", "blue"]),
          references.values.allSatisfy({ $0.count == 27 && $0.allSatisfy { (0...255).contains($0) } }),
          !manager.fileExists(atPath: root.appendingPathComponent("result.json").path) else { preflightFailure() }
    for name in fixtureNames {
      let url = root.appendingPathComponent(name)
      guard url.resolvingSymlinksInPath().path == url.path,
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
            values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, size > 0, size <= 16 * 1024 * 1024 else { preflightFailure() }
    }
    instance = NativeAppTestDriver(root: root, runID: runID, pixelReferences: references)
    // The argument domain wins over registration and persistence without changing
    // the release domain. The unique test bundle ID also isolates caches/support.
    var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    let overrides: [String: Any] = [
      "recordPlaybackHistory": false, "recordRecentFiles": false,
      "enableRecentDocumentsWorkaround": false, "resumeLastPosition": false,
      "SUEnableAutomaticChecks": false, "SUAutomaticallyUpdate": false,
      "ChengYingAutomaticUpdatesMigrationV1": true,
      "fileAccessGuideHasBeenShown": true, "actionAfterLaunch": 2,
      "quitWhenNoOpenedWindow": false, "pauseWhenOpen": false,
      "enableAdvancedSettings": false, "useUserDefinedConfDir": false,
      "currentInputConfigName": "ChengYing Default", "audioDevice": "auto",
      "subAutoLoadIINA": 0, "subAutoLoadSearchPath": "./*",
      "softVolume": 0, "enableHdrSupport": false,
    ]
    arguments.merge(overrides) { _, value in value }
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
  }

  private static func hasOwnedWorkspace(above root: URL) -> Bool {
    var directory = root
    for _ in 0..<8 {
      let marker = directory.appendingPathComponent(".test-app-workspace.json")
      if directory.lastPathComponent.hasSuffix(".noindex"),
         marker.resolvingSymlinksInPath().path == marker.path,
         let data = try? Data(contentsOf: marker), data.count < 4096,
         let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         object["format"] as? Int == 1,
         let identity = object["identity"] as? [UInt64], identity.count == 2,
         let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
         let device = attributes[.systemNumber] as? NSNumber,
         let inode = attributes[.systemFileNumber] as? NSNumber,
         identity == [device.uint64Value, inode.uint64Value],
         let token = object["token"] as? String, token.count == 32 { return true }
      let parent = directory.deletingLastPathComponent()
      if parent == directory { break }
      directory = parent
    }
    return false
  }

  private static func preflightFailure() -> Never {
    fputs("NATIVE_APP_TEST_PREFLIGHT_FAILED\n", stderr)
    exit(78)
  }

  static func startAfterLaunch() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let driver = instance else { preflightFailure() }
    DispatchQueue.main.async { driver.start() }
  }

  private func start() {
    observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                      object: NSApp, queue: .main) { [weak self] _ in
      guard let self, !self.terminal else { return }
      guard self.awaitingQuit else { self.fail("unexpected_application_termination"); return }
      guard PlayerCore.playerCores.count >= 2,
            PlayerCore.playerCores.allSatisfy({ $0.info.state == .shutDown }) else {
        self.fail("all_real_cores_shutdown_before_termination")
        return
      }
      self.record("all_real_cores_shutdown_before_termination")
      self.terminal = true
      self.writeReport(complete: true, passed: true)
      print("NATIVE_APP_TEST_COMPLETE")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 110) { [weak self] in
      guard let self, !self.terminal else { return }
      self.fail("overall_deadline")
    }
    let player = PlayerCore.first
    self.player = player
    wait("pristine_real_mpv_service", until: { player.mpv.getFlag(MPVProperty.idleActive) }) {
      player.openURL(self.fixture("red/red.mp4"), shouldAutoLoad: false)
      self.wait("native_autoplay_ready", until: {
        player.isUsingNativePlayback && player.info.state == .playing
      }) {
        self.verifyClock(player, advancing: true, label: "native_autoplay_shared_clock_advances") {
          self.checkInitialWindow(player)
        }
      }
    }
  }

  private func checkInitialWindow(_ player: PlayerCore) {
    guard player.mainWindow.loaded, let window = player.mainWindow.window, window.isVisible,
          window.windowController === player.mainWindow,
          player.mainWindow.videoView.window === window,
          player.mainWindow.volumeSlider != nil, player.mainWindow.playSlider != nil,
          player.mainWindow.menuActionHandler != nil else { fail("real_mainwindow_nib_outlets"); return }
    record("real_mainwindow_nib_outlets")
    guard player.playbackVolume == 0, player.info.volume == 0,
          player.mainWindow.volumeSlider.doubleValue == 0,
          player.mainWindow.volumeSlider.isEnabled else { fail("initial_volume_and_slider_zero"); return }
    record("initial_volume_and_slider_zero")
    let videoView = player.mainWindow.videoView
    guard !videoView.hasInitializedOpenGL, player.mpv.mpvRenderContext == nil,
          let surface = videoView.nativeSurface, surface.window === window,
          !surface.isHiddenOrHasHiddenAncestor, surface.alphaValue > 0,
          surface.visibleRect.width > 0, surface.visibleRect.height > 0,
          let rectangle = surface.displayedVideoRect, rectangle.intersects(surface.visibleRect),
          let layer = player.nativePlaybackOutput?.displayLayer,
          layer.superlayer === surface.layer, !layer.isHidden, layer.opacity > 0,
          layer.bounds.width > 0, layer.bounds.height > 0 else {
      fail("native_window_has_no_compatibility_gl"); return
    }
    record("native_window_has_no_compatibility_gl")
    guard NSApp.sendAction(#selector(MainMenuActionHandler.menuTogglePause(_:)),
                           to: player.mainWindow.menuActionHandler, from: NSMenuItem()) else {
      fail("real_pause_menu_action"); return
    }
    wait("real_pause_menu_action", until: { player.info.state == .paused && player.playbackIsPaused }) {
      self.wait("paused_initial_frame_matches_red", until: { self.pixel(player, is: .red) }) {
        self.verifyClock(player, advancing: false, label: "paused_clock_stays_still") {
          self.exerciseVolume(player)
        }
      }
    }
  }

  private func verifyClock(_ player: PlayerCore, advancing: Bool, label: String,
                           then continuation: @escaping () -> Void) {
    guard let session = player.nativePlaybackSession else { fail(label); return }
    let phase: NativePlaybackPhase = advancing ? .playing : .paused
    // These queries execute on the real session worker and read its shared
    // renderer clock. UI cache changes or a requested rate alone are not proof.
    session.captureCurrentState { firstResult in
      guard case .ready(let first) = firstResult, first.phase == phase,
            first.position.isFinite, first.volume == 0 else { self.fail(label); return }
      let began = ProcessInfo.processInfo.systemUptime
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        guard player.nativePlaybackSession === session else { self.fail(label); return }
        session.captureCurrentState { secondResult in
          guard case .ready(let second) = secondResult, second.phase == phase,
                second.generation == first.generation, second.revision == first.revision,
                second.position.isFinite, second.volume == 0 else { self.fail(label); return }
          let elapsed = ProcessInfo.processInfo.systemUptime - began
          let delta = second.position - first.position
          guard advancing ? (delta > 0.05 && delta < elapsed * 2 + 0.1) : abs(delta) < 0.03 else {
            self.fail(label); return
          }
          self.record(label)
          continuation()
        }
      }
    }
  }

  private static func matchesVolumePercent(_ actual: Double, _ expected: Double) -> Bool {
    actual.isFinite && expected.isFinite && abs(actual - expected) < 0.0001
  }

  private func exerciseVolume(_ player: PlayerCore) {
    let slider = player.mainWindow.volumeSlider!
    slider.doubleValue = 70
    guard let action = slider.action,
          NSApp.sendAction(action, to: slider.target, from: slider),
          let session = player.nativePlaybackSession else { fail("real_volume_slider_action"); return }
    session.captureCurrentState { result in
      guard case .ready(let snapshot) = result, snapshot.phase == .paused,
            abs(snapshot.volume - 0.7) < 0.001, Self.matchesVolumePercent(player.info.volume, 70) else {
        self.fail("real_volume_slider_action"); return
      }
      self.record("real_volume_slider_action")
      player.seek(absoluteSecond: 4.2)
      self.wait("paused_seek_presents_green_frame", until: {
        player.info.state == .paused && player.playbackIsPaused &&
          abs((player.playbackPosition ?? -1) - 4.2) < 0.075 && self.pixel(player, is: .green)
      }) { self.replaceRapidly(player) }
    }
  }

  private func replaceRapidly(_ player: PlayerCore) {
    var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments["pauseWhenOpen"] = true
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    let previousLayer = player.nativePlaybackOutput?.displayLayer
    player.openURL(fixture("red/red.mp4"), shouldAutoLoad: false)
    player.openURL(fixture("blue/blue.mp4"), shouldAutoLoad: false)
    wait("rapid_replace_presents_latest_blue_frame", until: {
      player.info.currentURL == self.fixture("blue/blue.mp4") && player.isUsingNativePlayback &&
        player.info.state == .paused && self.pixel(player, is: .blue)
    }) {
      guard previousLayer?.superlayer == nil else { self.fail("retired_layer_detached"); return }
      self.record("retired_layer_detached")
      guard player.playbackVolume == 0, player.info.volume == 0,
            player.mainWindow.volumeSlider.doubleValue == 0 else {
        self.fail("replacement_resets_volume_and_slider"); return
      }
      self.record("replacement_resets_volume_and_slider")
      player.mainWindow.window?.performClose(nil)
      self.wait("real_window_close_retires_native_session", until: {
        player.info.state == .idle && !player.isUsingNativePlayback &&
          player.mainWindow.window?.isVisible == false
      }) { self.exerciseCompatibility(player) }
    }
  }

  private func exerciseCompatibility(_ player: PlayerCore) {
    player.openURL(fixture("compat/compat.mp4"), shouldAutoLoad: false)
    wait("embedded_subtitle_routes_to_real_compatibility", timeout: 20, until: {
      !player.isUsingNativePlayback && player.info.state == .paused &&
        player.info.currentURL == self.fixture("compat/compat.mp4") &&
        !player.info.subTracks.isEmpty && player.mainWindow.window?.isVisible == true &&
        player.mpv.mpvRenderContext != nil && player.mainWindow.videoView.hasInitializedOpenGL
    }) {
      guard player.playbackVolume == 0, player.mainWindow.volumeSlider.doubleValue == 0 else {
        self.fail("compatibility_open_remains_silent"); return
      }
      self.record("compatibility_open_remains_silent")
      self.prepareActiveQuit()
    }
  }

  private func prepareActiveQuit() {
    // The first core stays loaded in compatibility, so this is a genuinely new core.
    let second = PlayerCore.newPlayerCore
    var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments["pauseWhenOpen"] = true
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    wait("second_pristine_real_mpv_service", until: { second.mpv.getFlag(MPVProperty.idleActive) }) {
      second.openURL(self.fixture("blue/blue.mp4"), shouldAutoLoad: false)
      self.wait("second_native_paused_blue_frame", until: {
        second.isUsingNativePlayback && second.info.state == .paused && second.playbackIsPaused &&
          self.pixel(second, is: .blue) &&
          self.player?.info.state == .paused
      }) {
        guard NSApp.sendAction(#selector(MainMenuActionHandler.menuTogglePause(_:)),
                               to: second.mainWindow.menuActionHandler, from: NSMenuItem()) else {
          self.fail("second_real_resume_menu_action"); return
        }
        self.record("second_real_resume_menu_action")
        self.wait("native_and_compatibility_ready_for_real_quit", until: {
          second.isUsingNativePlayback && second.info.state == .playing &&
            self.player?.info.state == .paused
        }) {
          self.verifyClock(second, advancing: true, label: "resumed_native_shared_clock_advances") {
            self.awaitingQuit = true
            self.writeReport(complete: false, passed: false)
            NSApp.terminate(nil)
          }
        }
      }
    }
  }

  private enum Color: String { case red, green, blue }

  private func pixel(_ player: PlayerCore, is expected: Color) -> Bool {
    // Inspect the immutable display-layer reference and its actually displayed
    // buffer, not worker counters or an enqueued-but-never-presented sample.
    guard #available(macOS 14.4, *),
          let layer = player.nativePlaybackOutput?.displayLayer,
          let reference = pixelReferences[expected.rawValue] else { return false }
    let renderer = layer.sampleBufferRenderer
    // The SDK explicitly returns nil from copyDisplayedPixelBuffer while its
    // clock has a nonzero rate. Never use this paused-image API as autoplay proof.
    guard CMTimebaseGetEffectiveRate(renderer.timebase) == 0,
          let buffer = renderer.displayedPixelBuffer() else { return false }
    return Self.matchesReference(buffer, reference)
  }

  private static func matchesReference(_ buffer: CVPixelBuffer, _ reference: [Int]) -> Bool {
    guard reference.count == 27, reference.allSatisfy({ (0...255).contains($0) }),
          CVPixelBufferGetWidth(buffer) == 160, CVPixelBufferGetHeight(buffer) == 96,
          CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
          CVPixelBufferGetPlaneCount(buffer) == 2,
          CVPixelBufferGetWidthOfPlane(buffer, 0) == 160, CVPixelBufferGetHeightOfPlane(buffer, 0) == 96,
          CVPixelBufferGetWidthOfPlane(buffer, 1) == 80, CVPixelBufferGetHeightOfPlane(buffer, 1) == 48,
          CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) >= 160,
          CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) >= 160,
          CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return false }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
          let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return false }
    var index = 0
    // Independently decoded FFmpeg references include luma as well as both
    // chroma channels. Nine distributed points reject a correct corner in an
    // otherwise broken or incorrectly sized displayed image.
    for y in [8, 48, 86] {
      for x in [8, 80, 150] {
        let row = luma.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
          .assumingMemoryBound(to: UInt8.self)
        let uv = chroma.advanced(by: (y / 2) * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
          .assumingMemoryBound(to: UInt8.self)
        let values = [Int(row[x]), Int(uv[(x / 2) * 2]), Int(uv[(x / 2) * 2 + 1])]
        for value in values {
          guard abs(value - reference[index]) <= 1 else { return false }
          index += 1
        }
      }
    }
    return true
  }

  private func fixture(_ name: String) -> URL { root.appendingPathComponent(name) }

  private func wait(_ label: String, timeout: Double = 12, until condition: @escaping () -> Bool,
                    then continuation: @escaping () -> Void) {
    pollRevision += 1
    let request = pollRevision
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    func poll() {
      guard !terminal, request == pollRevision else { return }
      if condition() {
        record(label)
        continuation()
      } else if ProcessInfo.processInfo.systemUptime >= deadline {
        fail(label)
      } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: poll)
      }
    }
    poll()
  }

  private func record(_ label: String) {
    checks.append(["label": label, "passed": true])
    print("NATIVE_APP_TEST_PASS: \(label)")
    writeReport(complete: false, passed: false)
  }

  private func fail(_ label: String) {
    guard !terminal else { return }
    terminal = true
    checks.append(["label": label, "passed": false])
    writeReport(complete: true, passed: false)
    fputs("NATIVE_APP_TEST_FAIL: \(label)\n", stderr)
    exit(1)
  }

  private func writeReport(complete: Bool, passed: Bool) {
    let report: [String: Any] = ["format": 1, "run_id": runID, "complete": complete,
                               "passed": passed, "checks": checks]
    do {
      let output = root.appendingPathComponent("result.json")
      guard output.resolvingSymlinksInPath().path == output.path else { throw CocoaError(.fileWriteInvalidFileName) }
      let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: output, options: .atomic)
    } catch {
      fputs("NATIVE_APP_TEST_REPORT_FAILED\n", stderr)
      exit(74)
    }
  }
}
#endif
