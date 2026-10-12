#if CHENGYING_NATIVE_APP_TESTS
import AppKit
import AVFoundation
import CoreVideo

/// Compiled only into the disposable CI application, never the release executable.
/// All player, controller, nib and rendering objects below are production objects.
final class NativeAppTestDriver {
  private static var instance: NativeAppTestDriver?
  private static let fixtureNames = ["red/red.mp4", "blue/blue.mp4", "compat/compat.mp4", "delayed/delayed.mp4"]
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
          Set(references.keys) == Set(["red", "green", "blue", "delayed_red"]),
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
      // Keep fixed numeric state in CI evidence without logging media paths.
      if case .ready(let snapshot) = result {
        print("NATIVE_APP_TEST_VOLUME: phase=\(snapshot.phase) output=\(snapshot.volume) info=\(player.info.volume) slider=\(slider.doubleValue)")
      } else {
        print("NATIVE_APP_TEST_VOLUME: capture_not_ready")
      }
      guard case .ready(let snapshot) = result, snapshot.phase == .paused,
            abs(snapshot.volume - 0.7) < 0.001, Self.matchesVolumePercent(player.info.volume, 70) else {
        self.fail("real_volume_slider_action"); return
      }
      self.record("real_volume_slider_action")
      player.seek(absoluteSecond: 4.2)
      self.wait("paused_seek_presents_green_frame", until: {
        player.info.state == .paused && player.playbackIsPaused &&
          abs((player.playbackPosition ?? -1) - 4.2) < 0.075 && self.pixel(player, is: .green)
      }) { self.exerciseABLoop(player) }
    }
  }

  private func exerciseABLoop(_ player: PlayerCore) {
    guard let window = player.mainWindow.window else { fail("ab_key_window_ready"); return }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(nil)
    player.mainWindow.beginControlInteraction()
    let slider = player.mainWindow.volumeSlider!
    slider.doubleValue = 0
    guard let action = slider.action, NSApp.sendAction(action, to: slider.target, from: slider) else {
      fail("ab_key_window_ready"); return
    }
    wait("ab_key_window_ready", until: { NSApp.keyWindow === window && window.isVisible }) {
      player.seek(absoluteSecond: 0)
      self.waitForNativePaused(player, position: 0, color: .red, label: "ab_start_is_exact_zero",
        extra: { player.playbackLoopA == nil && player.playbackLoopB == nil && player.getLoopMode() == .off }) {
        guard self.sendMarkerKey(player, start: true) else { self.fail("ab_left_bracket_shows_zero_marker"); return }
        self.waitForNativePaused(player, position: 0, color: .red, label: "ab_left_bracket_shows_zero_marker",
          extra: { self.markersMatch(player, start: 0, end: nil) }) {
          self.checkInvalidEndKey(player)
        }
      }
    }
  }

  private func sendMarkerKey(_ player: PlayerCore, start: Bool) -> Bool {
    guard let window = player.mainWindow.window, NSApp.keyWindow === window,
          !(window.firstResponder is NSTextInputClient),
          let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: start ? "[" : "]", charactersIgnoringModifiers: start ? "[" : "]",
            isARepeat: false, keyCode: start ? 33 : 30) else { return false }
    // Deliver only to this owned window's production controller, never post a
    // global event or call the marker implementation in place of key handling.
    player.mainWindow.keyDown(with: event)
    return true
  }

  private func checkInvalidEndKey(_ player: PlayerCore) {
    guard sendMarkerKey(player, start: false), let session = player.nativePlaybackSession else {
      fail("ab_equal_end_key_is_rejected"); return
    }
    // The controller's marker capture and this read-only query use the same
    // serial worker/main callback ordering. Inspect only after the key capture.
    session.captureCurrentState { result in
      guard case .ready(let snapshot) = result, snapshot.phase == .paused,
            snapshot.position == 0, snapshot.volume == 0,
            self.markersMatch(player, start: 0, end: nil) else {
        self.fail("ab_equal_end_key_is_rejected"); return
      }
      self.record("ab_equal_end_key_is_rejected")
      player.seek(absoluteSecond: 4.2)
      self.waitForNativePaused(player, position: 4.2, color: .green, label: "ab_end_capture_position_is_green") {
        guard self.sendMarkerKey(player, start: false) else { self.fail("ab_right_bracket_shows_valid_paused_range"); return }
        self.waitForNativePaused(player, position: 0, color: .red, label: "ab_right_bracket_shows_valid_paused_range",
          extra: { self.markersMatch(player, start: 0, end: 4.2) }) {
          self.checkInvalidEndEdits(player)
        }
      }
    }
  }

  private func checkInvalidEndEdits(_ player: PlayerCore) {
    player.requestNativeLoopAction(.moveB(-1)) { below in
      guard case .invalid = below, self.markersMatch(player, start: 0, end: 4.2) else {
        self.fail("ab_invalid_end_edits_preserve_range"); return
      }
      player.requestNativeLoopAction(.moveB(0)) { equal in
        guard case .invalid = equal, self.markersMatch(player, start: 0, end: 4.2) else {
          self.fail("ab_invalid_end_edits_preserve_range"); return
        }
        self.record("ab_invalid_end_edits_preserve_range")
        self.checkInvalidKnobNotifications(player)
      }
    }
  }

  private func checkInvalidKnobNotifications(_ player: PlayerCore) {
    let slider = player.mainWindow.playSlider!
    // A drag updates the real view before posting its existing notification.
    // Merely setting PlayerCore properties would miss a rejected-but-stale knob.
    slider.abLoopA.doubleValue = 70
    NotificationCenter.default.post(name: .iinaPlaySliderLoopKnobChanged, object: slider.abLoopA)
    waitForNativePaused(player, position: 0, color: .red, label: "ab_invalid_dragged_a_restores_visible_marker",
      extra: { self.markersMatch(player, start: 0, end: 4.2) }) {
      slider.abLoopB.doubleValue = 0
      NotificationCenter.default.post(name: .iinaPlaySliderLoopKnobChanged, object: slider.abLoopB)
      self.waitForNativePaused(player, position: 0, color: .red, label: "ab_invalid_dragged_b_restores_visible_marker",
        extra: { self.markersMatch(player, start: 0, end: 4.2) }) {
        self.checkFileLoopPreservesRange(player)
      }
    }
  }

  private func checkFileLoopPreservesRange(_ player: PlayerCore) {
    guard NSApp.sendAction(#selector(MainMenuActionHandler.menuFileLoop(_:)),
                           to: player.mainWindow.menuActionHandler, from: NSMenuItem()) else {
      fail("ab_file_loop_selection_keeps_markers"); return
    }
    waitForNativePaused(player, position: 0, color: .red, label: "ab_file_loop_selection_keeps_markers",
      extra: { self.fileLoopIsSaved(player) && self.markersMatch(player, start: 0, end: 4.2) }) {
      self.checkABSeekBounds(player)
    }
  }

  private func checkABSeekBounds(_ player: PlayerCore) {
    // Expected values are independent of the production clamp helper. The end
    // remains half-open and the actual paused worker clock must stay below B.
    player.seek(absoluteSecond: 50)
    waitForNativePaused(player, position: 4.2 - 0.000001, color: .green, label: "ab_absolute_seek_stays_before_end",
      extra: { self.markersMatch(player, start: 0, end: 4.2) },
      snapshotCheck: { $0.position >= 0 && $0.position < 4.2 }) {
      player.seek(relativeSecond: -50, option: .exact)
      self.waitForNativePaused(player, position: 0, color: .red, label: "ab_relative_seek_stays_at_start",
        extra: { self.markersMatch(player, start: 0, end: 4.2) }) {
        guard self.sendABMenu(player) else { self.fail("ab_menu_clear_preserves_file_loop"); return }
        self.waitForNativePaused(player, position: 0, color: .red, label: "ab_menu_clear_preserves_file_loop",
          extra: { self.fileLoopIsSaved(player) && self.markersMatch(player, start: nil, end: nil) }) {
          self.checkABMenuCycle(player)
        }
      }
    }
  }

  private func checkABMenuCycle(_ player: PlayerCore) {
    guard sendABMenu(player) else { fail("ab_menu_cycle_sets_a"); return }
    waitForNativePaused(player, position: 0, color: .red, label: "ab_menu_cycle_sets_a",
      extra: { self.markersMatch(player, start: 0, end: nil) }) {
      player.seek(absoluteSecond: 4.2)
      self.waitForNativePaused(player, position: 4.2, color: .green, label: "ab_menu_end_position_is_green") {
        guard self.sendABMenu(player) else { self.fail("ab_menu_cycle_sets_b"); return }
        self.waitForNativePaused(player, position: 0, color: .red, label: "ab_menu_cycle_sets_b",
          extra: { self.markersMatch(player, start: 0, end: 4.2) }) {
          guard self.sendABMenu(player) else { self.fail("ab_menu_cycle_clears_range"); return }
          self.waitForNativePaused(player, position: 0, color: .red, label: "ab_menu_cycle_clears_range",
            extra: { self.fileLoopIsSaved(player) && self.markersMatch(player, start: nil, end: nil) }) {
            player.setLoopMode(.off)
            self.waitForNativePaused(player, position: 0, color: .red, label: "ab_cleanup_remains_native_without_gl",
              extra: { player.getLoopMode() == .off && self.markersMatch(player, start: nil, end: nil) }) {
              player.mainWindow.endControlInteraction()
              self.exerciseDelayedFirstVideo(player)
            }
          }
        }
      }
    }
  }

  private func sendABMenu(_ player: PlayerCore) -> Bool {
    NSApp.sendAction(#selector(MainMenuActionHandler.menuABLoop(_:)),
                     to: player.mainWindow.menuActionHandler, from: NSMenuItem())
  }

  private func fileLoopIsSaved(_ player: PlayerCore) -> Bool {
    player.getLoopMode() == .file &&
      Preference.savedLoopMode(in: .standard, domain: Bundle.main.bundleIdentifier) == .file
  }

  private func markersMatch(_ player: PlayerCore, start: Double?, end: Double?) -> Bool {
    func matches(_ actual: Double?, _ expected: Double?) -> Bool {
      switch (actual, expected) {
      case (nil, nil): return true
      case (let actual?, let expected?): return actual.isFinite && abs(actual - expected) < 0.000001
      default: return false
      }
    }
    guard matches(player.playbackLoopA, start), matches(player.playbackLoopB, end),
          let duration = player.info.videoDuration?.second, duration > 0,
          let window = player.mainWindow.window, let slider = player.mainWindow.playSlider,
          slider.window === window, !slider.isHiddenOrHasHiddenAncestor, slider.alphaValue > 0,
          slider.visibleRect.width > 0, slider.visibleRect.height > 0 else { return false }
    let status: PlaybackInfo.LoopStatus = start == nil ? .cleared : (end == nil ? .aSet : .bSet)
    guard player.info.abLoopStatus == status else { return false }
    for (knob, value) in [(slider.abLoopA, start), (slider.abLoopB, end)] {
      guard knob.superview === slider, knob.window === window else { return false }
      if let value {
        guard !knob.isHiddenOrHasHiddenAncestor, knob.alphaValue > 0,
              knob.visibleRect.width > 0, knob.visibleRect.height > 0,
              abs(knob.doubleValue - value / duration * 100) < 0.0001 else { return false }
      } else if !knob.isHidden { return false }
    }
    return true
  }

  private func waitForNativePaused(_ player: PlayerCore, position: Double, color: Color, label: String,
                                   extra: @escaping () -> Bool = { true },
                                   snapshotCheck: @escaping (NativePlaybackSnapshot) -> Bool = { _ in true },
                                   then continuation: @escaping () -> Void) {
    guard let session = player.nativePlaybackSession else { fail(label); return }
    pollRevision += 1
    let request = pollRevision
    let deadline = ProcessInfo.processInfo.systemUptime + 12
    func poll() {
      guard !self.terminal, request == self.pollRevision else { return }
      guard player.nativePlaybackSession === session else { self.fail(label); return }
      // Marker captures first return to main, where they enqueue a loop refill.
      // Do not queue this query until the expected marker state is visible;
      // otherwise an older paused snapshot can arrive after that new UI state.
      guard extra() else {
        if ProcessInfo.processInfo.systemUptime >= deadline { self.fail(label) }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: poll) }
        return
      }
      session.captureCurrentState { result in
        guard !self.terminal, request == self.pollRevision else { return }
        if case .ready(let snapshot) = result, snapshot.phase == .paused, snapshot.volume == 0,
           snapshot.position.isFinite, abs(snapshot.position - position) < 0.0000001,
           snapshotCheck(snapshot), player.isUsingNativePlayback, player.playbackIsPaused,
           player.info.state == .paused, !player.mainWindow.videoView.hasInitializedOpenGL,
           player.mpv.mpvRenderContext == nil, extra(), self.pixel(player, is: color) {
          self.record(label)
          continuation()
        } else if ProcessInfo.processInfo.systemUptime >= deadline {
          self.fail(label)
        } else {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: poll)
        }
      }
    }
    poll()
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

  private func exerciseDelayedFirstVideo(_ player: PlayerCore) {
    var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments["pauseWhenOpen"] = true
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    player.openURL(fixture("delayed/delayed.mp4"), shouldAutoLoad: false)
    wait("delayed_native_paused_open_ready", until: {
      player.info.currentURL == self.fixture("delayed/delayed.mp4") &&
        player.isUsingNativePlayback && player.info.state == .paused && player.playbackIsPaused &&
        player.mainWindow.window?.isVisible == true && player.playbackVolume == 0 &&
        player.mainWindow.volumeSlider.doubleValue == 0
    }) {
      // The selected video starts at 1.5 seconds, while audio starts at zero.
      // A ready flag or decoded-frame count cannot substitute for this actual
      // zero-rate, zero-clock image readback through the real player window.
      self.waitForNativePaused(player, position: 0, color: .delayedRed,
        label: "delayed_paused_first_frame_at_zero") {
        self.verifyClock(player, advancing: false, label: "delayed_paused_shared_clock_stays_still") {
          guard NSApp.sendAction(#selector(MainMenuActionHandler.menuTogglePause(_:)),
                                 to: player.mainWindow.menuActionHandler, from: NSMenuItem()) else {
            self.fail("delayed_real_resume_menu_action"); return
          }
          self.record("delayed_real_resume_menu_action")
          self.wait("delayed_resume_ready", until: {
            player.isUsingNativePlayback && player.info.state == .playing && !player.playbackIsPaused &&
              player.info.currentURL == self.fixture("delayed/delayed.mp4") &&
              player.playbackVolume == 0 && !player.mainWindow.videoView.hasInitializedOpenGL &&
              player.mpv.mpvRenderContext == nil
          }) {
            self.verifyClock(player, advancing: true, label: "delayed_resume_shared_clock_advances") {
              self.replaceRapidly(player)
            }
          }
        }
      }
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

  private enum Color: String { case red, green, blue, delayedRed = "delayed_red" }

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
