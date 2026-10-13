#if CHENGYING_NATIVE_APP_TESTS
import AppKit
import AVFoundation
import CoreVideo

/// Compiled only into the disposable CI application, never the release executable.
/// All player, controller, nib and rendering objects below are production objects.
final class NativeAppTestDriver {
  private static var instance: NativeAppTestDriver?
  private static let fixtureNames = ["red/red.mp4", "blue/blue.mp4", "compat/compat.mp4", "delayed/delayed.mp4"]
  private enum Scenario: String { case baseline, queue }
  private let root: URL
  private let runID: String
  private let scenario: Scenario
  private let pixelReferences: [String: [Int]]
  private var checks: [[String: Any]] = []
  private var observer: NSObjectProtocol?
  private var shutdownObserver: NSObjectProtocol?
  private var terminal = false
  private var awaitingQuit = false
  private var pollRevision = 0
  private var player: PlayerCore?
  private var quitPlayers: [PlayerCore] = []
  private var quitNativeLayer: AVSampleBufferDisplayLayer?
  private var quitRequestedAt: TimeInterval?
  private var shutdownNotifications: [ObjectIdentifier: Int] = [:]
  private var handoffStartedAt: TimeInterval?
  private var startedAt: TimeInterval?
  private var queueItemIdentities: [ObjectIdentifier] = []
  private let queueNames = ["red/red.mp4", "blue/blue.mp4", "red/red.mp4"]

  private init(root: URL, runID: String, scenario: Scenario, pixelReferences: [String: [Int]]) {
    self.root = root
    self.runID = runID
    self.scenario = scenario
    self.pixelReferences = pixelReferences
  }

  static func prepareForLaunch() {
    dispatchPrecondition(condition: .onQueue(.main))
    let environment = ProcessInfo.processInfo.environment
    guard let scenario = Scenario(rawValue: environment["CHENGYING_NATIVE_APP_TEST_SCENARIO"] ?? "baseline") else {
      preflightFailure()
    }
    guard environment["CI"] == "true",
          environment["GITHUB_ACTIONS"] == "true",
          environment["RUNNER_ENVIRONMENT"] == "github-hosted",
          environment["CHENGYING_NATIVE_PLAYBACK"] == "1",
          let runID = environment["CHENGYING_NATIVE_APP_TEST_RUN_ID"],
          UUID(uuidString: runID) != nil,
          let uuid = UUID(uuidString: environment["CHENGYING_NATIVE_APP_TEST_BUILD_ID"] ?? runID),
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
          (payload["scenario"] as? String ?? "baseline") == scenario.rawValue,
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
    instance = NativeAppTestDriver(root: root, runID: runID, scenario: scenario, pixelReferences: references)
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
      "enableControlBarAutoHide": true, "oscPosition": 2,
    ]
    arguments.merge(overrides) { _, value in value }
    if scenario == .queue {
      arguments["pauseWhenOpen"] = true
      arguments["playlistAutoPlayNext"] = true
      arguments["keepOpenOnFileEnd"] = true
    }
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
    startedAt = ProcessInfo.processInfo.systemUptime
    shutdownObserver = NotificationCenter.default.addObserver(forName: .iinaPlayerShutdown,
                                                              object: nil, queue: .main) { [weak self] note in
      guard let self, let core = note.object as? PlayerCore else { return }
      self.shutdownNotifications[ObjectIdentifier(core), default: 0] += 1
      if self.awaitingQuit { self.reportShutdownState(stage: "shutdown_notification") }
    }
    observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                      object: NSApp, queue: .main) { [weak self] _ in
      guard let self, !self.terminal else { return }
      guard self.awaitingQuit else { self.fail("unexpected_application_termination"); return }
      self.reportShutdownState(stage: "will_terminate")
      if self.scenario == .queue {
        self.completeQueueTermination()
        return
      }
      let registered = PlayerCore.playerCores
      guard self.quitPlayers.count == 2, self.quitPlayers[0] !== self.quitPlayers[1],
            registered.count >= 2,
            self.quitPlayers.allSatisfy({ expected in registered.contains { $0 === expected } }),
            registered.allSatisfy({ $0.info.state == .shutDown }),
            self.quitPlayers.allSatisfy({
              $0.info.state == .shutDown && $0.nativePlaybackSession == nil &&
                $0.nativePlaybackOutput == nil && $0.mpv.mpvRenderContext == nil &&
                $0.mainWindow.loaded && $0.mainWindow.videoView.isUninited
            }), self.quitNativeLayer != nil, self.quitNativeLayer?.superlayer == nil else {
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
    if scenario == .queue {
      startQueueScenario()
      return
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
      }) { self.exerciseViewport(player) }
    }
  }

  private func exerciseViewport(_ player: PlayerCore) {
    guard let window = player.mainWindow.window else { fail("viewport_key_window_ready"); return }
    let originalFrame = window.frame
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(nil)
    player.mainWindow.beginControlInteraction()
    let slider = player.mainWindow.volumeSlider!
    slider.doubleValue = 0
    guard let action = slider.action, NSApp.sendAction(action, to: slider.target, from: slider) else {
      fail("viewport_key_window_ready"); return
    }
    wait("viewport_key_window_ready", until: { NSApp.keyWindow === window && window.isVisible }) {
      self.waitForNativePaused(player, position: 4.2, color: .green,
        label: "viewport_initial_attached_geometry",
        extra: { self.viewportMatches(player, scale: 1, panX: 0, panY: 0) }) {
        self.exerciseViewportKeys(player, originalFrame: originalFrame)
      }
    }
  }

  private func exerciseViewportKeys(_ player: PlayerCore, originalFrame: NSRect) {
    // Expected values are independent of VideoToolsViewport.applying. Pan is
    // one twentieth of the fitted dimension, divided by the accepted zoom.
    typealias Step = (label: String, action: VideoToolsShortcuts.Action, repeats: Int,
                      scale: Double, panX: Double, panY: Double)
    let pan = 0.05 / 1.5
    let steps: [Step] = [
      ("viewport_zoom_in_key_updates_layer", .zoomIn, 1, 1.1, 0, 0),
      ("viewport_zoom_out_key_updates_layer", .zoomOut, 1, 1, 0, 0),
      ("viewport_pan_setup_zoomed", .zoomIn, 5, 1.5, 0, 0),
      ("viewport_pan_right_key_updates_layer", .panRight, 1, 1.5, pan, 0),
      ("viewport_pan_left_key_updates_layer", .panLeft, 2, 1.5, -pan, 0),
      ("viewport_pan_up_key_updates_layer", .panUp, 1, 1.5, -pan, -pan),
      ("viewport_pan_down_key_updates_layer", .panDown, 2, 1.5, -pan, pan),
    ]
    func advance(_ index: Int) {
      guard index < steps.count else {
        self.exerciseViewportResize(player, originalFrame: originalFrame, pan: pan)
        return
      }
      let step = steps[index]
      for _ in 0..<step.repeats {
        guard self.sendViewportKey(player, action: step.action) else { self.fail(step.label); return }
      }
      self.waitForNativePaused(player, position: 4.2, color: .green, label: step.label,
        extra: { self.viewportMatches(player, scale: step.scale, panX: step.panX, panY: step.panY) }) {
        advance(index + 1)
      }
    }
    advance(0)
  }

  private func sendViewportKey(_ player: PlayerCore, action: VideoToolsShortcuts.Action) -> Bool {
    guard let window = player.mainWindow.window, NSApp.keyWindow === window,
          !(window.firstResponder is NSTextInputClient) else { return false }
    let code: UInt16
    let characters: String
    let modifiers: NSEvent.ModifierFlags
    switch action {
    case .zoomIn: code = 24; characters = "="; modifiers = []
    case .zoomOut: code = 27; characters = "-"; modifiers = []
    case .panLeft: code = 123; characters = "\u{f702}"; modifiers = [.command, .shift, .numericPad, .function]
    case .panRight: code = 124; characters = "\u{f703}"; modifiers = [.command, .shift, .numericPad, .function]
    case .panDown: code = 125; characters = "\u{f701}"; modifiers = [.command, .shift, .numericPad, .function]
    case .panUp: code = 126; characters = "\u{f700}"; modifiers = [.command, .shift, .numericPad, .function]
    case .resetViewport: code = 29; characters = "0"; modifiers = [.command, .shift]
    default: return false
    }
    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: code),
      VideoToolsShortcuts.resolve(event, hasMedia: true, isTextInput: false) == action else { return false }
    // Exercise the owned window's production event handler. This is not OS
    // keyboard injection, and never calls the viewport implementation directly.
    player.mainWindow.keyDown(with: event)
    return true
  }

  private func exerciseViewportResize(_ player: PlayerCore, originalFrame: NSRect, pan: Double) {
    guard let window = player.mainWindow.window, let surface = player.mainWindow.videoView.nativeSurface,
          let screen = window.screen else { fail("viewport_resize_recomputes_normalized_pan"); return }
    let originalSize = surface.bounds.size
    let originalPan = surface.pan
    var resized = originalFrame
    resized.size.width += originalFrame.width + 96 < screen.visibleFrame.width ? 96 : -96
    resized.size.height += originalFrame.height + 64 < screen.visibleFrame.height ? 64 : -64
    guard resized.width >= window.minSize.width, resized.height >= window.minSize.height,
          resized.width > 0, resized.height > 0 else {
      fail("viewport_resize_recomputes_normalized_pan"); return
    }
    window.setFrame(resized, display: true, animate: false)
    waitForNativePaused(player, position: 4.2, color: .green,
      label: "viewport_resize_recomputes_normalized_pan", extra: {
        self.viewportMatches(player, scale: 1.5, panX: -pan, panY: pan) &&
          (abs(surface.bounds.width - originalSize.width) > 1 || abs(surface.bounds.height - originalSize.height) > 1) &&
          (abs(surface.pan.x - originalPan.x) > 0.01 || abs(surface.pan.y - originalPan.y) > 0.01)
      }) {
      guard self.sendViewportKey(player, action: .resetViewport) else {
        self.fail("viewport_reset_key_restores_fit"); return
      }
      self.waitForNativePaused(player, position: 4.2, color: .green,
        label: "viewport_reset_key_restores_fit",
        extra: { self.viewportMatches(player, scale: 1, panX: 0, panY: 0) }) {
        window.setFrame(originalFrame, display: true, animate: false)
        self.waitForNativePaused(player, position: 4.2, color: .green,
          label: "viewport_window_and_state_restored", extra: {
            abs(window.frame.minX - originalFrame.minX) < 0.01 &&
              abs(window.frame.minY - originalFrame.minY) < 0.01 &&
              abs(window.frame.width - originalFrame.width) < 0.01 &&
              abs(window.frame.height - originalFrame.height) < 0.01 &&
              self.viewportMatches(player, scale: 1, panX: 0, panY: 0)
          }) {
          self.verifyClock(player, advancing: false, label: "viewport_paused_clock_stays_still") {
            player.mainWindow.endControlInteraction()
            self.exerciseABLoop(player)
          }
        }
      }
    }
  }

  private func viewportMatches(_ player: PlayerCore, scale: Double, panX: Double, panY: Double) -> Bool {
    guard player.isUsingNativePlayback, !player.mainWindow.videoView.hasInitializedOpenGL,
          player.mpv.mpvRenderContext == nil, let window = player.mainWindow.window,
          let surface = player.mainWindow.videoView.nativeSurface,
          let layer = player.nativePlaybackOutput?.displayLayer,
          surface.window === window, !surface.isHiddenOrHasHiddenAncestor, surface.alphaValue > 0,
          surface.visibleRect.width > 0, surface.visibleRect.height > 0,
          surface.displayLayer === layer, layer.superlayer === surface.layer,
          !layer.isHidden, layer.opacity > 0, surface.layer?.masksToBounds == true,
          surface.geometry?.codedSize == CGSize(width: 160, height: 96),
          surface.geometry?.pixelAspectRatio == 1, surface.geometry?.rotationDegrees == 0,
          abs(player.nativeViewport.scale - scale) < 0.000000001,
          abs(player.nativeViewport.panX - panX) < 0.000000001,
          abs(player.nativeViewport.panY - panY) < 0.000000001 else { return false }
    player.mainWindow.videoView.layoutSubtreeIfNeeded()
    surface.layoutSubtreeIfNeeded()
    // The decoded pixel buffer remains a source image after zoom or pan. It
    // cannot certify the final physical-screen transform; these checks inspect
    // the real attached Core Animation model-layer geometry instead.
    return Self.matchesViewportLayout(surface, layer: layer, scale: scale, panX: panX, panY: panY) &&
      abs(layer.contentsScale - window.backingScaleFactor) < 0.000000001
  }

  private static func matchesViewportLayout(_ surface: NativePlaybackSurface, layer: AVSampleBufferDisplayLayer,
                                            scale: Double, panX: Double, panY: Double) -> Bool {
    guard let geometry = surface.geometry, let rectangle = surface.displayedVideoRect,
          surface.bounds.width > 0, surface.bounds.height > 0,
          scale.isFinite, scale > 0, panX.isFinite, panY.isFinite else { return false }
    let width = geometry.codedSize.width * geometry.pixelAspectRatio
    let height = geometry.codedSize.height
    guard width.isFinite, height.isFinite, width > 0, height > 0 else { return false }
    let rotated = geometry.rotationDegrees == 90 || geometry.rotationDegrees == 270
    let fitted = min(surface.bounds.width / (rotated ? height : width),
                     surface.bounds.height / (rotated ? width : height))
    let scaled = CGSize(width: width * fitted * scale, height: height * fitted * scale)
    let rotatedSize = rotated ? CGSize(width: scaled.height, height: scaled.width) : scaled
    let offset = CGPoint(x: rotatedSize.width * panX, y: -rotatedSize.height * panY)
    let center = CGPoint(x: surface.bounds.midX + offset.x, y: surface.bounds.midY + offset.y)
    let expected = CGRect(x: center.x - rotatedSize.width / 2, y: center.y - rotatedSize.height / 2,
                          width: rotatedSize.width, height: rotatedSize.height)
    let transform = CATransform3DGetAffineTransform(layer.transform)
    let rotation: CGAffineTransform
    switch geometry.rotationDegrees {
    case 0: rotation = .identity
    case 90: rotation = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
    case 180: rotation = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
    case 270: rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
    default: return false
    }
    let pairs: [(CGFloat, CGFloat)] = [
      (surface.zoom, scale), (surface.pan.x, offset.x), (surface.pan.y, offset.y),
      (layer.bounds.minX, 0), (layer.bounds.minY, 0),
      (layer.bounds.width, scaled.width), (layer.bounds.height, scaled.height),
      (layer.position.x, center.x), (layer.position.y, center.y),
      (layer.anchorPoint.x, 0.5), (layer.anchorPoint.y, 0.5),
      (rectangle.minX, expected.minX), (rectangle.minY, expected.minY),
      (rectangle.width, expected.width), (rectangle.height, expected.height),
      (layer.frame.minX, expected.minX), (layer.frame.minY, expected.minY),
      (layer.frame.width, expected.width), (layer.frame.height, expected.height),
    ]
    return pairs.allSatisfy { $0.isFinite && $1.isFinite && abs($0 - $1) < 0.01 } &&
      CATransform3DIsAffine(layer.transform) && transform == rotation && layer.videoGravity == .resize
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
              self.exerciseClipPreview(player)
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
    // Local inventory is asynchronous even on a pristine core. Pin ownership
    // only after its real session exists, within the original single deadline.
    var observedSession = player.nativePlaybackSession
    var observedGeneration = observedSession == nil ? nil : player.videoToolsMediaGeneration
    pollRevision += 1
    let request = pollRevision
    let deadline = ProcessInfo.processInfo.systemUptime + 12
    func poll() {
      guard !self.terminal, request == self.pollRevision else { return }
      if observedSession == nil, let available = player.nativePlaybackSession {
        observedSession = available
        observedGeneration = player.videoToolsMediaGeneration
      }
      guard let session = observedSession else {
        if ProcessInfo.processInfo.systemUptime >= deadline { self.fail(label) }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: poll) }
        return
      }
      guard player.nativePlaybackSession === session,
            player.videoToolsMediaGeneration == observedGeneration else { self.fail(label); return }
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
        guard player.nativePlaybackSession === session,
              player.videoToolsMediaGeneration == observedGeneration else { self.fail(label); return }
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
      self.closeWhilePreviewing(player)
    }
  }

  private struct PreviewControls {
    let panel: VideoToolsViewController
    let start: NSTextField
    let end: NSTextField
    let toggle: NSButton
  }

  private func previewControls(_ player: PlayerCore) -> PreviewControls? {
    guard let panel = player.mainWindow.quickSettingView.children.compactMap({ $0 as? VideoToolsViewController }).first,
          panel.isViewLoaded, panel.view.window === player.mainWindow.window else { return nil }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let views = descendants(panel.view)
    let fields = views.compactMap { $0 as? NSTextField }.filter { ($0.delegate as AnyObject?) === panel }
    let starts = fields.filter { $0.accessibilityLabel() == NSLocalizedString("videotools.start", comment: "Start") }
    let ends = fields.filter { $0.accessibilityLabel() == NSLocalizedString("videotools.end", comment: "End") }
    let buttons = views.compactMap { $0 as? NSButton }.filter {
      ($0.target as AnyObject?) === panel && $0.action == NSSelectorFromString("toggleRangePreview:")
    }
    guard starts.count == 1, ends.count == 1, buttons.count == 1,
          starts[0] !== ends[0], starts[0].isEnabled, ends[0].isEnabled, buttons[0].isEnabled else { return nil }
    return PreviewControls(panel: panel, start: starts[0], end: ends[0], toggle: buttons[0])
  }

  private func previewActive(_ player: PlayerCore, start: Double, end: Double) -> Bool {
    previewOwnedRange(player, start: start, end: end) && player.info.state == .playing && !player.playbackIsPaused
  }

  private func previewOwnedRange(_ player: PlayerCore, start: Double, end: Double) -> Bool {
    guard player.isUsingNativePlayback, !player.mainWindow.videoView.hasInitializedOpenGL,
          player.mpv.mpvRenderContext == nil, player.nativePreviewInProgress,
          player.playbackVolume == 0,
          let range = player.videoToolsLoopRange else { return false }
    return abs(range.start - start) < 0.000001 && abs(range.end - end) < 0.000001
  }

  private func sendPreviewToggle(_ controls: PreviewControls) -> Bool {
    guard controls.toggle.isEnabled, let action = controls.toggle.action,
          (controls.toggle.target as AnyObject?) === controls.panel else { return false }
    return NSApp.sendAction(action, to: controls.toggle.target, from: controls.toggle)
  }

  private func editPreviewField(_ field: NSTextField, text: String, panel: VideoToolsViewController) -> Bool {
    guard field.isEnabled, field.window != nil, (field.delegate as AnyObject?) === panel else { return false }
    field.stringValue = text
    // Exercise the existing AppKit text delegate entry, not the private timer or
    // Core preview implementation. This is not physical keyboard injection.
    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    return true
  }

  private func exerciseClipPreview(_ player: PlayerCore) {
    player.seek(absoluteSecond: 1.25)
    waitForNativePaused(player, position: 1.25, color: .red, label: "preview_baseline_paused_red",
      extra: { !player.nativePreviewInProgress && player.videoToolsLoopRange == nil && player.getLoopMode() == .off }) {
      guard let window = player.mainWindow.window,
            NSApp.sendAction(#selector(MainMenuActionHandler.menuShowVideoTools(_:)),
                             to: player.mainWindow.menuActionHandler, from: NSMenuItem()) else {
        self.fail("preview_real_tools_menu_attached"); return
      }
      let originalFrame = window.frame
      self.wait("preview_real_tools_menu_attached", until: {
        player.mainWindow.sideBarStatus == .settings && player.mainWindow.quickSettingView.currentTab == .tools &&
          player.mainWindow.isSidebarVisible && self.previewControls(player) != nil && player.isUsingNativePlayback &&
          !player.mainWindow.videoView.hasInitializedOpenGL && player.mpv.mpvRenderContext == nil
      }) {
        guard let controls = self.previewControls(player) else { self.fail("preview_real_tools_menu_attached"); return }
        self.wait("preview_tools_auto_preview", until: { self.previewActive(player, start: 1.25, end: 6.25) }) {
          self.verifyClock(player, advancing: true, label: "preview_auto_shared_clock_advances") {
            self.editPreviewRange(player, controls: controls, originalFrame: originalFrame)
          }
        }
      }
    }
  }

  private func editPreviewRange(_ player: PlayerCore, controls: PreviewControls, originalFrame: NSRect) {
    guard editPreviewField(controls.start, text: "00:02.000000", panel: controls.panel),
          editPreviewField(controls.end, text: "00:03.800000", panel: controls.panel),
          editPreviewField(controls.start, text: "00:02.750000", panel: controls.panel),
          editPreviewField(controls.end, text: "00:03.250000", panel: controls.panel),
          previewActive(player, start: 1.25, end: 6.25) else {
      fail("preview_fields_debounce_pending"); return
    }
    // Same-turn edits must not synchronously apply any intermediate range.
    // The production timer is responsible for the eventual latest-only commit.
    record("preview_fields_debounce_pending")
    wait("preview_latest_fields_apply", until: { self.previewActive(player, start: 2.75, end: 3.25) }) {
      guard let window = player.mainWindow.window else { self.fail("preview_chrome_actually_hides"); return }
      window.makeFirstResponder(nil)
      let view = player.mainWindow.videoView
      let desired = window.convertPoint(toScreen: view.convert(
        NSPoint(x: view.bounds.width * 0.25, y: view.bounds.midY), to: nil))
      let pointer = NSEvent.mouseLocation
      // Move only this disposable test window, placing the existing cursor over
      // its picture instead of controls. Never move/inject the system cursor.
      window.setFrameOrigin(NSPoint(x: window.frame.minX + pointer.x - desired.x,
                                    y: window.frame.minY + pointer.y - desired.y))
      player.mainWindow.hideUIAndCursor()
      self.wait("preview_chrome_actually_hides", until: {
        player.mainWindow.sidebarAutoHidden && player.mainWindow.sideBarStatus == .settings &&
          !player.mainWindow.isSidebarVisible && controls.panel.view.isHiddenOrHasHiddenAncestor &&
          self.previewActive(player, start: 2.75, end: 3.25)
      }) {
        self.observeHiddenPreviewWraps(player) {
          player.mainWindow.beginControlInteraction()
          window.setFrame(originalFrame, display: true, animate: false)
          self.wait("preview_stop_button_restores_state", recordSuccess: false, until: {
            player.mainWindow.isSidebarVisible && !controls.panel.view.isHiddenOrHasHiddenAncestor
          }) {
            guard self.sendPreviewToggle(controls) else { self.fail("preview_stop_button_restores_state"); return }
            self.waitForNativePaused(player, position: 1.25, color: .red,
              label: "preview_stop_button_restores_state", extra: {
                !player.nativePreviewInProgress && player.videoToolsLoopRange == nil && player.getLoopMode() == .off
              }) {
              self.checkStoppedPreview(player, controls: controls)
            }
          }
        }
      }
    }
  }

  private func observeHiddenPreviewWraps(_ player: PlayerCore, completion: @escaping () -> Void) {
    guard let session = player.nativePlaybackSession else { fail("preview_hidden_chrome_keeps_looping"); return }
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    var last: Double?
    var wraps = 0
    var observations = 0
    var revision: UInt64 = 0
    func poll() {
      guard !self.terminal else { return }
      session.captureCurrentState { result in
        guard !self.terminal else { return }
        if case .ready(let snapshot) = result {
          guard player.nativePlaybackSession === session, snapshot.volume == 0,
                snapshot.phase == .playing, snapshot.wantsPlayback,
                snapshot.position >= 2.75 && snapshot.position <= 3.25,
                player.mainWindow.sidebarAutoHidden,
                self.previewOwnedRange(player, start: 2.75, end: 3.25) else {
            self.fail("preview_hidden_chrome_keeps_looping"); return
          }
          observations += 1
          if let last, snapshot.position < last - 0.2 { wraps += 1 }
          last = snapshot.position
          revision = snapshot.revision
        }
        if wraps >= 2 && observations >= 4 {
          print("NATIVE_APP_PREVIEW_LOOP: observations=\(observations) wraps=\(wraps) revision=\(revision)")
          self.record("preview_hidden_chrome_keeps_looping")
          completion()
        } else if ProcessInfo.processInfo.systemUptime >= deadline {
          print("NATIVE_APP_PREVIEW_LOOP: observations=\(observations) wraps=\(wraps) revision=\(revision) position=\(last ?? -1)")
          self.fail("preview_hidden_chrome_keeps_looping")
        } else {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: poll)
        }
      }
    }
    poll()
  }

  private func checkStoppedPreview(_ player: PlayerCore, controls: PreviewControls) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      guard !self.terminal else { return }
      guard let session = player.nativePlaybackSession else { self.fail("preview_stopped_stays_stopped"); return }
      session.captureCurrentState { result in
        guard case .ready(let snapshot) = result, snapshot.phase == .paused,
              abs(snapshot.position - 1.25) < 0.000001, snapshot.volume == 0,
              !player.nativePreviewInProgress, player.videoToolsLoopRange == nil else {
          self.fail("preview_stopped_stays_stopped"); return
        }
        self.record("preview_stopped_stays_stopped")
        guard self.sendPreviewToggle(controls) else { self.fail("preview_manual_seek_cancels"); return }
        self.wait("preview_manual_seek_cancels", recordSuccess: false, until: {
          self.previewActive(player, start: 2.75, end: 3.25)
        }) {
          guard NSApp.sendAction(#selector(MainMenuActionHandler.menuTogglePause(_:)),
                                 to: player.mainWindow.menuActionHandler, from: NSMenuItem()) else {
            self.fail("preview_manual_seek_cancels"); return
          }
          self.wait("preview_manual_seek_cancels", recordSuccess: false,
            until: { player.playbackIsPaused && player.info.state == .paused }) {
            guard let duration = player.info.videoDuration?.second, duration > 4.2 else {
              self.fail("preview_manual_seek_cancels"); return
            }
            let slider = player.mainWindow.playSlider!
            slider.doubleValue = 4.2 / duration * slider.maxValue
            guard let action = slider.action, NSApp.sendAction(action, to: slider.target, from: slider) else {
              self.fail("preview_manual_seek_cancels"); return
            }
            self.waitForNativePaused(player, position: 4.2, color: .green,
              label: "preview_manual_seek_cancels", extra: {
                !player.nativePreviewInProgress && player.videoToolsLoopRange == nil
              }) {
              self.finishPreviewPanel(player)
            }
          }
        }
      }
    }
  }

  private func finishPreviewPanel(_ player: PlayerCore) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      guard !self.terminal else { return }
      guard let session = player.nativePlaybackSession else { self.fail("preview_manual_seek_stays_cancelled"); return }
      session.captureCurrentState { result in
        guard case .ready(let snapshot) = result, snapshot.phase == .paused,
              abs(snapshot.position - 4.2) < 0.000001, snapshot.volume == 0,
              !player.nativePreviewInProgress, player.videoToolsLoopRange == nil else {
          self.fail("preview_manual_seek_stays_cancelled"); return
        }
        self.record("preview_manual_seek_stays_cancelled")
        player.mainWindow.hideSideBar(animate: false) {
          self.waitForNativePaused(player, position: 4.2, color: .green,
            label: "preview_panel_close_remains_native", extra: {
              player.mainWindow.sideBarStatus == .hidden && !player.nativePreviewInProgress &&
                player.videoToolsLoopRange == nil && player.getLoopMode() == .off
            }) {
            player.mainWindow.endControlInteraction()
            self.exerciseDelayedFirstVideo(player)
          }
        }
      }
    }
  }

  private func closeWhilePreviewing(_ player: PlayerCore) {
    guard NSApp.sendAction(#selector(MainMenuActionHandler.menuShowVideoTools(_:)),
                           to: player.mainWindow.menuActionHandler, from: NSMenuItem()) else {
      fail("preview_window_close_begins_with_applied_range"); return
    }
    wait("preview_window_close_begins_with_applied_range", until: {
      player.mainWindow.sideBarStatus == .settings && self.previewControls(player) != nil &&
        self.previewActive(player, start: 0, end: 5)
    }) {
      guard let layer = player.nativePlaybackOutput?.displayLayer else {
        self.fail("preview_window_close_cancels_and_detaches"); return
      }
      player.mainWindow.window?.performClose(nil)
      self.wait("real_window_close_retires_native_session", until: {
        player.info.state == .idle && !player.isUsingNativePlayback &&
          player.mainWindow.window?.isVisible == false
      }) {
        print("NATIVE_APP_CLOSE_STATE: preview=\(player.nativePreviewInProgress) session=\(player.nativePlaybackSession != nil) output=\(player.nativePlaybackOutput != nil) capturedLayerAttached=\(layer.superlayer != nil) nativeSurface=\(player.mainWindow.videoView.isUsingNativeSurface) gl=\(player.mainWindow.videoView.hasInitializedOpenGL)")
        guard !player.nativePreviewInProgress, layer.superlayer == nil,
              player.nativePlaybackSession == nil else {
          self.fail("preview_window_close_cancels_and_detaches"); return
        }
        self.record("preview_window_close_cancels_and_detaches")
        self.exerciseCompatibility(player)
      }
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
      self.exerciseLoadedHandoff()
    }
  }

  private func exerciseLoadedHandoff() {
    handoffStartedAt = ProcessInfo.processInfo.systemUptime
    // Keep the original core loaded so newPlayerCore cannot reuse its MPV history.
    let candidate = PlayerCore.newPlayerCore
    guard let original = player, candidate !== original, original.info.state == .paused else {
      fail("handoff_pristine_real_mpv_service"); return
    }
    wait("handoff_pristine_real_mpv_service", until: {
      candidate.mpv.getFlag(MPVProperty.idleActive) && candidate.mpv.getString(MPVProperty.path) == nil &&
        candidate.nativePlaybackSession == nil && candidate.mpv.mpvRenderContext == nil
    }) {
      candidate.openURL(self.fixture("red/red.mp4"), shouldAutoLoad: false)
      self.waitForNativePaused(candidate, position: 0, color: .red,
        label: "handoff_native_paused_red_ready", extra: {
          candidate.info.currentURL == self.fixture("red/red.mp4") && candidate.mainWindow.window?.isVisible == true
        }) {
        guard let window = candidate.mainWindow.window else { self.fail("handoff_key_window_ready"); return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        candidate.mainWindow.beginControlInteraction()
        self.wait("handoff_key_window_ready", until: { NSApp.keyWindow === window }) {
          self.configureHandoffRange(candidate)
        }
      }
    }
  }

  private func configureHandoffRange(_ player: PlayerCore) {
    guard sendMarkerKey(player, start: true) else { fail("handoff_zero_a_marker"); return }
    waitForNativePaused(player, position: 0, color: .red, label: "handoff_zero_a_marker",
      extra: { self.markersMatch(player, start: 0, end: nil) }) {
      player.seek(absoluteSecond: 5.5)
      self.waitForNativePaused(player, position: 5.5, color: .green, label: "handoff_end_capture_green") {
        guard self.sendMarkerKey(player, start: false) else { self.fail("handoff_ab_range_ready"); return }
        self.waitForNativePaused(player, position: 0, color: .red, label: "handoff_ab_range_ready",
          extra: { self.markersMatch(player, start: 0, end: 5.5) }) {
          player.seek(absoluteSecond: 4.2)
          self.waitForNativePaused(player, position: 4.2, color: .green, label: "handoff_paused_green_target") {
            self.configureHandoffState(player)
          }
        }
      }
    }
  }

  private func configureHandoffState(_ player: PlayerCore) {
    for _ in 0..<5 {
      guard sendViewportKey(player, action: .zoomIn) else { fail("handoff_native_nondefault_state"); return }
    }
    guard sendViewportKey(player, action: .panRight), sendViewportKey(player, action: .panUp),
          let slider = player.mainWindow.volumeSlider, let sliderAction = slider.action,
          let session = player.nativePlaybackSession else { fail("handoff_native_nondefault_state"); return }
    slider.doubleValue = 37
    let speed = NSMenuItem()
    speed.representedObject = 1.25
    guard NSApp.sendAction(sliderAction, to: slider.target, from: slider),
          NSApp.sendAction(#selector(MainMenuActionHandler.menuChangeSpeed(_:)),
                           to: player.mainWindow.menuActionHandler, from: speed) else {
      fail("handoff_native_nondefault_state"); return
    }
    session.captureCurrentState { result in
      guard case .ready(let snapshot) = result, player.nativePlaybackSession === session,
            snapshot.phase == .paused, !snapshot.wantsPlayback,
            abs(snapshot.position - 4.2) < 0.0000001,
            abs(Double(snapshot.volume) - 0.37) < 0.000001,
            abs(Double(snapshot.rate) - 1.25) < 0.000001,
            self.markersMatch(player, start: 0, end: 5.5),
            self.viewportMatches(player, scale: 1.5, panX: 0.05 / 1.5, panY: -0.05 / 1.5),
            self.pixel(player, is: .green), let window = player.mainWindow.window,
            let layer = player.nativePlaybackOutput?.displayLayer else {
        self.fail("handoff_native_nondefault_state"); return
      }
      self.record("handoff_native_nondefault_state")
      // A real existing menu command forces compatibility without writing any
      // media. Its observable audio-delay change proves deferred replay occurred.
      let delay = NSMenuItem()
      delay.representedObject = 0.25
      guard NSApp.sendAction(#selector(MainMenuActionHandler.menuChangeAudioDelay(_:)),
                             to: player.mainWindow.menuActionHandler, from: delay) else {
        self.fail("handoff_real_audio_delay_menu_action"); return
      }
      self.record("handoff_real_audio_delay_menu_action")
      self.verifyHandoffRestoration(player, window: window, retiredLayer: layer)
    }
  }

  private func verifyHandoffRestoration(_ player: PlayerCore, window: NSWindow,
                                         retiredLayer: AVSampleBufferDisplayLayer) {
    wait("handoff_same_window_mpv_ready", until: {
      !player.isUsingNativePlayback && player.info.state == .paused &&
        player.info.currentURL == self.fixture("red/red.mp4") &&
        player.mpv.getString(MPVProperty.path) == self.fixture("red/red.mp4").path &&
        player.mainWindow.window === window && window.isVisible &&
        player.mainWindow.videoView.window === window &&
        player.mainWindow.videoView.hasInitializedOpenGL && player.mpv.mpvRenderContext != nil
    }) {
      guard retiredLayer.superlayer == nil, player.nativePlaybackSession == nil,
            player.nativePlaybackOutput == nil, player.mainWindow.videoView.nativeSurface == nil else {
        self.fail("handoff_native_resources_detached"); return
      }
      self.record("handoff_native_resources_detached")
      self.wait("handoff_mpv_transport_restored", until: {
        self.handoffMPVTransportMatches(player)
      }) {
        self.wait("handoff_mpv_viewport_and_ab_restored", until: {
          self.handoffMPVViewportAndRangeMatch(player) && self.markersMatch(player, start: 0, end: 5.5)
        }) {
          self.wait("handoff_deferred_menu_action_applied", until: {
            abs(player.mpv.getDouble(MPVOption.Audio.audioDelay) - 0.25) < 0.000001
          }) {
            let position = player.mpv.getDouble(MPVProperty.timePos)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
              guard self.handoffMPVTransportMatches(player), self.handoffMPVViewportAndRangeMatch(player),
                    player.mainWindow.window === window,
                    abs(player.mpv.getDouble(MPVProperty.timePos) - position) < 0.03,
                    abs(player.mpv.getDouble(MPVOption.Audio.audioDelay) - 0.25) < 0.000001 else {
                self.fail("handoff_paused_mpv_stays_still"); return
              }
              self.record("handoff_paused_mpv_stays_still")
              self.closeHandoffCore(player, window: window)
            }
          }
        }
      }
    }
  }

  private func handoffMPVTransportMatches(_ player: PlayerCore) -> Bool {
    !player.isUsingNativePlayback && player.info.state == .paused &&
      player.info.currentURL == fixture("red/red.mp4") &&
      player.mpv.getString(MPVProperty.path) == fixture("red/red.mp4").path &&
      player.mpv.getFlag(MPVOption.PlaybackControl.pause) &&
      Self.matchesHandoffValue(player.mpv.getDouble(MPVProperty.timePos), 4.2, tolerance: 0.05) &&
      Self.matchesHandoffValue(player.mpv.getDouble(MPVOption.Audio.volume), 37, tolerance: 0.0001) &&
      Self.matchesHandoffValue(player.mpv.getDouble(MPVOption.PlaybackControl.speed), 1.25, tolerance: 0.000001) &&
      Self.matchesHandoffValue(player.mainWindow.volumeSlider.doubleValue, 37, tolerance: 0.0001)
  }

  private func handoffMPVViewportAndRangeMatch(_ player: PlayerCore) -> Bool {
    // Read the real libmpv properties, not the accepted native model that has
    // already been retired. A=0 must remain an enabled point, never the "no" sentinel.
    guard let a = player.mpv.getString(MPVOption.PlaybackControl.abLoopA), a != "no",
          let b = player.mpv.getString(MPVOption.PlaybackControl.abLoopB), b != "no",
          let count = player.mpv.getString(MPVOption.PlaybackControl.abLoopCount), count == "inf" else { return false }
    return Self.matchesHandoffValue(player.mpv.getDouble(MPVOption.Video.videoZoom), log2(1.5), tolerance: 0.000001) &&
      Self.matchesHandoffValue(player.mpv.getDouble(MPVOption.Video.videoPanX), 0.05 / 1.5, tolerance: 0.000001) &&
      Self.matchesHandoffValue(player.mpv.getDouble(MPVOption.Video.videoPanY), -0.05 / 1.5, tolerance: 0.000001) &&
      Self.matchesHandoffValue(player.mpv.getDouble(MPVOption.PlaybackControl.abLoopA), 0, tolerance: 0.000001) &&
      Self.matchesHandoffValue(player.mpv.getDouble(MPVOption.PlaybackControl.abLoopB), 5.5, tolerance: 0.000001)
  }

  private static func matchesHandoffValue(_ actual: Double, _ expected: Double, tolerance: Double) -> Bool {
    actual.isFinite && expected.isFinite && tolerance.isFinite && tolerance > 0 && abs(actual - expected) < tolerance
  }

  private func closeHandoffCore(_ player: PlayerCore, window: NSWindow) {
    player.mainWindow.endControlInteraction()
    window.performClose(nil)
    wait("handoff_real_close_stops_mpv", until: {
      player.info.state == .idle && !window.isVisible && player.mpv.getFlag(MPVProperty.idleActive)
    }) {
      player.shutdown()
      self.wait("handoff_extra_core_shutdown", until: {
        player.info.state == .shutDown && player.nativePlaybackSession == nil &&
          player.nativePlaybackOutput == nil && player.mpv.mpvRenderContext == nil && player.mainWindow.videoView.isUninited &&
          self.player?.info.state == .paused
      }) {
        // The original two-core active-quit scenario remains unchanged. This
        // additional registered core has already proven its own full teardown.
        self.prepareActiveQuit()
      }
    }
  }

  // This independent process retains the baseline process's exact checks and
  // deadlines. Only public production commands construct or navigate its queue.
  private func startQueueScenario() {
    let player = PlayerCore.first
    self.player = player
    player.setLoopMode(.off)
    wait("queue_pristine_service", until: {
      player.mpv.getFlag(MPVProperty.idleActive) && player.mpv.getString(MPVProperty.path) == nil &&
        player.mpv.mpvRenderContext == nil
    }) {
      guard player.openMediaURLs(self.queueNames.map(self.fixture), shouldAutoLoad: false) == 3 else {
        self.fail("queue_explicit_duplicate_urls_accepted"); return
      }
      self.record("queue_explicit_duplicate_urls_accepted")
      self.waitQueueFrame(player, index: 0, color: .red, label: "queue_first_actual_red_frame") {
        self.queueItemIdentities = player.info.playlist.map(ObjectIdentifier.init)
        guard Set(self.queueItemIdentities).count == 3 else { self.fail("queue_distinct_duplicate_identities"); return }
        self.record("queue_distinct_duplicate_identities")
        self.queueNavigate(player)
      }
    }
  }

  private func queueProjectionMatches(_ player: PlayerCore, index: Int, names: [String]? = nil) -> Bool {
    let paths = (names ?? queueNames).map { fixture($0).path }
    let items = player.info.playlist
    return player.hasNativePlaybackQueue && player.isUsingNativePlayback &&
      items.map(\.filename) == paths && items.indices.contains(index) &&
      items.indices.allSatisfy { items[$0].isCurrent == ($0 == index) && items[$0].isPlaying == ($0 == index) } &&
      (queueItemIdentities.isEmpty || items.map(ObjectIdentifier.init) == queueItemIdentities) &&
      player.info.currentURL?.path == paths[index] && player.mpv.mpvRenderContext == nil &&
      !player.mainWindow.videoView.hasInitializedOpenGL
  }

  private func waitQueueFrame(_ player: PlayerCore, index: Int, color: Color, label: String,
                              names: [String]? = nil, then continuation: @escaping () -> Void) {
    // Wait for the real new session, then query its worker and read its paused
    // display buffer. A selection marker alone cannot satisfy this assertion.
    wait(label, recordSuccess: false, until: {
      self.queueProjectionMatches(player, index: index, names: names) && player.info.state == .paused &&
        player.playbackIsPaused && player.playbackVolume == 0 &&
        player.mainWindow.volumeSlider?.doubleValue == 0 && self.pixel(player, is: color)
    }) {
      self.waitForNativePaused(player, position: 0, color: color, label: label,
        extra: { self.queueProjectionMatches(player, index: index, names: names) }) { continuation() }
    }
  }

  private func setQueueVolume(_ player: PlayerCore) -> Bool {
    guard let slider = player.mainWindow.volumeSlider, let action = slider.action else { return false }
    slider.doubleValue = 37
    return NSApp.sendAction(action, to: slider.target, from: slider) && player.playbackVolume == 37
  }

  private func queueNavigate(_ player: PlayerCore) {
    guard setQueueVolume(player) else { fail("queue_volume_before_next"); return }
    record("queue_volume_before_next")
    player.navigateInPlaylist(nextMedia: true)
    waitQueueFrame(player, index: 1, color: .blue, label: "queue_next_blue_resets_volume") {
      guard self.setQueueVolume(player) else { self.fail("queue_volume_before_previous"); return }
      self.record("queue_volume_before_previous")
      player.navigateInPlaylist(nextMedia: false)
      self.waitQueueFrame(player, index: 0, color: .red, label: "queue_previous_red_resets_volume") {
        guard self.setQueueVolume(player) else { self.fail("queue_volume_before_duplicate"); return }
        self.record("queue_volume_before_duplicate")
        player.playFileInPlaylist(2)
        self.waitQueueFrame(player, index: 2, color: .red, label: "queue_selected_duplicate_resets_volume") {
          player.playFileInPlaylist(1)
          // These commands occur in one main turn, while the old session is
          // retiring. The final accepted pause must survive the new item probe.
          player.resume()
          player.togglePause()
          player.togglePause()
          player.pause()
          self.waitQueueFrame(player, index: 1, color: .blue, label: "queue_loading_latest_pause_intent") {
            self.verifyClock(player, advancing: false, label: "queue_loading_pause_clock_stable") {
              player.playFileInPlaylist(2)
              self.waitQueueFrame(player, index: 2, color: .red, label: "queue_last_item_ready_for_eof") {
                self.queueOffEOF(player)
              }
            }
          }
        }
      }
    }
  }

  private func queueOffEOF(_ player: PlayerCore) {
    player.setLoopMode(.off)
    player.seek(absoluteSecond: 8.8)
    waitForNativePaused(player, position: 8.8, color: .blue, label: "queue_off_last_seek_near_eof") {
      player.resume()
      self.wait("queue_off_last_reaches_real_eof", recordSuccess: false, until: {
        self.queueProjectionMatches(player, index: 2) && player.playbackAtEOF && player.playbackIsPaused
      }) {
        guard let session = player.nativePlaybackSession else { self.fail("queue_off_last_reaches_real_eof"); return }
        session.captureCurrentState { result in
          guard case .ready(let snapshot) = result, snapshot.phase == .ended,
                snapshot.position >= 8.95, !snapshot.wantsPlayback,
                self.queueProjectionMatches(player, index: 2) else {
            self.fail("queue_off_last_reaches_real_eof"); return
          }
          self.record("queue_off_last_reaches_real_eof")
          player.seek(absoluteSecond: 4.2)
          self.waitForNativePaused(player, position: 4.2, color: .green, label: "queue_eof_seek_preserves_target") {
            player.resume()
            self.waitQueuePlayingPosition(player, index: 2, range: 4.2..<5.5,
              label: "queue_eof_seek_resume_not_rewound", recordSuccess: true) {
              self.verifyClock(player, advancing: true, label: "queue_eof_seek_actual_clock_advances") {
                player.pause()
                self.wait("queue_eof_resume_paused", until: { player.info.state == .paused && player.playbackIsPaused }) {
                  self.queueFileEOF(player)
                }
              }
            }
          }
        }
      }
    }
  }

  private func queueFileEOF(_ player: PlayerCore) {
    player.setLoopMode(.file)
    player.seek(absoluteSecond: 8.8)
    waitForNativePaused(player, position: 8.8, color: .blue, label: "queue_file_seek_near_eof") {
      player.resume()
      self.waitQueuePlayingPosition(player, index: 2, range: 0..<1,
        label: "queue_file_wraps_same_duplicate") {
        player.pause()
        self.waitQueueWrappedFrame(player, index: 2, label: "queue_file_wraps_same_duplicate") {
          player.setLoopMode(.playlist)
          player.seek(absoluteSecond: 8.8)
          self.waitForNativePaused(player, position: 8.8, color: .blue, label: "queue_list_seek_near_eof") {
            player.resume()
            self.wait("queue_list_wraps_to_first_duplicate", recordSuccess: false, until: {
              self.queueProjectionMatches(player, index: 0) && player.info.state == .playing
            }) {
              player.pause()
              self.waitQueueWrappedFrame(player, index: 0, label: "queue_list_wraps_to_first_duplicate") {
                self.queueCancelWithNewOpen(player)
              }
            }
          }
        }
      }
    }
  }

  private func waitQueuePlayingPosition(_ player: PlayerCore, index: Int, range: Range<Double>, label: String,
                                        recordSuccess: Bool = false, then continuation: @escaping () -> Void) {
    guard let session = player.nativePlaybackSession else { fail(label); return }
    let generation = player.videoToolsMediaGeneration
    pollRevision += 1
    let request = pollRevision
    let deadline = ProcessInfo.processInfo.systemUptime + 12
    func retry() {
      if ProcessInfo.processInfo.systemUptime >= deadline { self.fail(label) }
      else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: poll) }
    }
    func poll() {
      guard !self.terminal, self.pollRevision == request else { return }
      guard player.nativePlaybackSession === session, player.videoToolsMediaGeneration == generation else {
        self.fail(label); return
      }
      session.captureCurrentState { result in
        guard !self.terminal, self.pollRevision == request else { return }
        guard player.nativePlaybackSession === session, player.videoToolsMediaGeneration == generation else {
          self.fail(label); return
        }
        if case .ready(let snapshot) = result, snapshot.phase == .playing, snapshot.wantsPlayback,
           snapshot.volume == 0, range.contains(snapshot.position), self.queueProjectionMatches(player, index: index) {
          if recordSuccess { self.record(label) }
          continuation()
        } else { retry() }
      }
    }
    poll()
  }

  private func waitQueueWrappedFrame(_ player: PlayerCore, index: Int, label: String,
                                     then continuation: @escaping () -> Void) {
    wait(label, recordSuccess: false, until: {
      self.queueProjectionMatches(player, index: index) && player.info.state == .paused &&
        player.playbackIsPaused && self.pixel(player, is: .red)
    }) {
      guard let session = player.nativePlaybackSession else { self.fail(label); return }
      session.captureCurrentState { result in
        guard case .ready(let snapshot) = result, snapshot.phase == .paused, !snapshot.wantsPlayback,
              snapshot.position >= 0, snapshot.position < 2, snapshot.volume == 0,
              player.nativePlaybackSession === session, self.queueProjectionMatches(player, index: index),
              player.mainWindow.volumeSlider.doubleValue == 0 else { self.fail(label); return }
        self.record(label)
        continuation()
      }
    }
  }

  private func queueCancelWithNewOpen(_ player: PlayerCore) {
    player.setLoopMode(.off)
    guard let layer = player.nativePlaybackOutput?.displayLayer else { fail("queue_new_open_cancels_pending_selection"); return }
    player.playFileInPlaylist(2)
    player.openURL(fixture("blue/blue.mp4"), shouldAutoLoad: false)
    queueItemIdentities = []
    wait("queue_new_open_cancels_pending_selection", recordSuccess: false, until: {
      !player.hasNativePlaybackQueue && player.info.currentURL == self.fixture("blue/blue.mp4") &&
        player.isUsingNativePlayback && player.info.state == .paused && layer.superlayer == nil
    }) {
      self.waitForNativePaused(player, position: 0, color: .blue, label: "queue_new_open_cancels_pending_selection") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
          guard !player.hasNativePlaybackQueue, player.info.currentURL == self.fixture("blue/blue.mp4"),
                player.playbackIsPaused, player.playbackVolume == 0, self.pixel(player, is: .blue) else {
            self.fail("queue_cancelled_selection_stays_cancelled"); return
          }
          self.record("queue_cancelled_selection_stays_cancelled")
          guard player.openMediaURLs(self.queueNames.map(self.fixture), shouldAutoLoad: false) == 3 else {
            self.fail("queue_reopen_for_loaded_handoff"); return
          }
          self.waitQueueFrame(player, index: 0, color: .red, label: "queue_reopen_for_loaded_handoff") {
            self.queueItemIdentities = player.info.playlist.map(ObjectIdentifier.init)
            player.playFileInPlaylist(2)
            self.waitQueueFrame(player, index: 2, color: .red, label: "queue_handoff_duplicate_selected") {
              self.configureQueueHandoff(player)
            }
          }
        }
      }
    }
  }

  private func configureQueueHandoff(_ player: PlayerCore) {
    guard let window = player.mainWindow.window else { fail("queue_handoff_key_window"); return }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(nil)
    player.mainWindow.beginControlInteraction()
    wait("queue_handoff_key_window", until: { window.isKeyWindow }) {
      guard self.sendMarkerKey(player, start: true) else { self.fail("queue_handoff_zero_a"); return }
      self.wait("queue_handoff_zero_a", until: { player.playbackLoopA == 0 && player.playbackLoopB == nil }) {
        player.seek(absoluteSecond: 5.5)
        self.waitForNativePaused(player, position: 5.5, color: .green, label: "queue_handoff_b_capture") {
          guard self.sendMarkerKey(player, start: false) else { self.fail("queue_handoff_ab_ready"); return }
          self.waitForNativePaused(player, position: 0, color: .red, label: "queue_handoff_ab_ready",
            extra: { self.markersMatch(player, start: 0, end: 5.5) }) {
            player.seek(absoluteSecond: 4.2)
            self.waitForNativePaused(player, position: 4.2, color: .green, label: "queue_handoff_green_target") {
              for _ in 0..<5 {
                guard self.sendViewportKey(player, action: .zoomIn) else { self.fail("queue_handoff_state_ready"); return }
              }
              let speed = NSMenuItem()
              speed.representedObject = 1.25
              guard self.sendViewportKey(player, action: .panRight), self.sendViewportKey(player, action: .panUp),
                    self.setQueueVolume(player),
                    NSApp.sendAction(#selector(MainMenuActionHandler.menuChangeSpeed(_:)),
                                     to: player.mainWindow.menuActionHandler, from: speed),
                    let session = player.nativePlaybackSession, let layer = player.nativePlaybackOutput?.displayLayer else {
                self.fail("queue_handoff_state_ready"); return
              }
              session.captureCurrentState { result in
                guard case .ready(let snapshot) = result, snapshot.phase == .paused, !snapshot.wantsPlayback,
                      abs(snapshot.position - 4.2) < 0.0000001,
                      abs(Double(snapshot.volume) - 0.37) < 0.000001, abs(Double(snapshot.rate) - 1.25) < 0.000001,
                      self.queueProjectionMatches(player, index: 2), self.pixel(player, is: .green),
                      self.viewportMatches(player, scale: 1.5, panX: 0.05 / 1.5, panY: -0.05 / 1.5) else {
                  self.fail("queue_handoff_state_ready"); return
                }
                self.record("queue_handoff_state_ready")
                let delay = NSMenuItem()
                delay.representedObject = 0.25
                guard NSApp.sendAction(#selector(MainMenuActionHandler.menuChangeAudioDelay(_:)),
                                       to: player.mainWindow.menuActionHandler, from: delay) else {
                  self.fail("queue_real_menu_handoff"); return
                }
                self.record("queue_real_menu_handoff")
                self.verifyQueueHandoff(player, window: window, layer: layer)
              }
            }
          }
        }
      }
    }
  }

  private func actualMPVQueueMatches(_ player: PlayerCore, names: [String], selected: Int) -> Bool {
    // Read one real MPV_NODE snapshot. Duplicate paths must have distinct MPV
    // IDs; neither the native projection nor a requested index is evidence.
    Self.matchesMPVQueue(player.mpv.getNode(MPVProperty.playlist),
                         paths: names.map { fixture($0).path }, selected: selected)
  }

  private static func matchesMPVQueue(_ node: Any?, paths: [String], selected: Int) -> Bool {
    guard let entries = node as? [[String: Any?]], entries.count == paths.count,
          entries.indices.contains(selected) else { return false }
    let ids = entries.compactMap { $0["id"] as? Int64 }
    guard ids.count == paths.count, ids.allSatisfy({ $0 >= 0 }), Set(ids).count == ids.count else { return false }
    return entries.indices.allSatisfy { index in
      entries[index]["filename"] as? String == paths[index] &&
        (entries[index]["current"] as? Bool ?? false) == (index == selected) &&
        (entries[index]["playing"] as? Bool ?? false) == (index == selected)
    }
  }

  private func verifyQueueHandoff(_ player: PlayerCore, window: NSWindow, layer: AVSampleBufferDisplayLayer) {
    wait("queue_loaded_whole_plan_mpv_restored", until: {
      !player.hasNativePlaybackQueue && self.handoffMPVTransportMatches(player) &&
        self.handoffMPVViewportAndRangeMatch(player) && self.markersMatch(player, start: 0, end: 5.5) &&
        self.actualMPVQueueMatches(player, names: self.queueNames, selected: 2) &&
        abs(player.mpv.getDouble(MPVOption.Audio.audioDelay) - 0.25) < 0.000001
    }) {
      guard player.mainWindow.window === window, window.isVisible,
            player.mainWindow.videoView.hasInitializedOpenGL, player.mpv.mpvRenderContext != nil,
            player.nativePlaybackSession == nil, player.nativePlaybackOutput == nil,
            player.mainWindow.videoView.nativeSurface == nil, layer.superlayer == nil else {
        self.fail("queue_loaded_handoff_same_window_detached"); return
      }
      self.record("queue_loaded_handoff_same_window_detached")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        guard self.handoffMPVTransportMatches(player), self.handoffMPVViewportAndRangeMatch(player),
              self.actualMPVQueueMatches(player, names: self.queueNames, selected: 2) else {
          self.fail("queue_loaded_handoff_remains_paused"); return
        }
        self.record("queue_loaded_handoff_remains_paused")
        self.closeQueueCore(player, label: "queue_first_core", then: { self.startUnsupportedQueue(player) })
      }
    }
  }

  private func startUnsupportedQueue(_ first: PlayerCore) {
    let second = PlayerCore.newPlayerCore
    guard second !== first else { fail("queue_second_pristine_service"); return }
    quitPlayers = [first, second]
    queueItemIdentities = []
    let names = ["red/red.mp4", "compat/compat.mp4", "blue/blue.mp4", "red/red.mp4"]
    second.setLoopMode(.off)
    wait("queue_second_pristine_service", until: {
      second.mpv.getFlag(MPVProperty.idleActive) && second.mpv.getString(MPVProperty.path) == nil &&
        second.mpv.mpvRenderContext == nil
    }) {
      guard second.openMediaURLs(names.map(self.fixture), shouldAutoLoad: false) == 4 else {
        self.fail("queue_unsupported_plan_initial_red"); return
      }
      self.waitQueueFrame(second, index: 0, color: .red, label: "queue_unsupported_plan_initial_red", names: names) {
        guard let layer = second.nativePlaybackOutput?.displayLayer, let window = second.mainWindow.window else {
          self.fail("queue_unsupported_whole_plan_fallback"); return
        }
        second.playFileInPlaylist(1)
        self.wait("queue_unsupported_whole_plan_fallback", until: {
          !second.hasNativePlaybackQueue && !second.isUsingNativePlayback && second.info.state == .paused &&
            second.info.currentURL == self.fixture("compat/compat.mp4") &&
            second.mpv.getString(MPVProperty.path) == self.fixture("compat/compat.mp4").path &&
            !second.info.subTracks.isEmpty && self.actualMPVQueueMatches(second, names: names, selected: 1) &&
            second.mpv.getFlag(MPVOption.PlaybackControl.pause) &&
            abs(second.mpv.getDouble(MPVProperty.timePos)) < 0.05 &&
            second.mpv.getDouble(MPVOption.Audio.volume) == 0 && second.mainWindow.volumeSlider.doubleValue == 0
        }) {
          guard second.mainWindow.window === window, window.isVisible,
                second.mainWindow.videoView.hasInitializedOpenGL, second.mpv.mpvRenderContext != nil,
                second.nativePlaybackSession == nil, second.nativePlaybackOutput == nil,
                second.mainWindow.videoView.nativeSurface == nil, layer.superlayer == nil else {
            self.fail("queue_unsupported_old_layer_detached"); return
          }
          self.record("queue_unsupported_old_layer_detached")
          self.closeQueueCore(second, label: "queue_second_core") {
            self.awaitingQuit = true
            self.quitRequestedAt = ProcessInfo.processInfo.systemUptime
            self.writeReport(complete: false, passed: false)
            Self.performTerminationFromRunLoop {
              guard !self.terminal, self.awaitingQuit else { return }
              NSApp.terminate(nil)
            }
          }
        }
      }
    }
  }

  private func closeQueueCore(_ player: PlayerCore, label: String, then continuation: @escaping () -> Void) {
    guard let window = player.mainWindow.window else { fail(label + "_close"); return }
    player.mainWindow.endControlInteraction()
    window.performClose(nil)
    wait(label + "_close", until: {
      player.info.state == .idle && !window.isVisible && player.mpv.getFlag(MPVProperty.idleActive) &&
        !player.hasNativePlaybackQueue && player.nativePlaybackSession == nil && player.nativePlaybackOutput == nil
    }) {
      player.shutdown()
      self.wait(label + "_shutdown", until: {
        player.info.state == .shutDown && player.mpv.mpvRenderContext == nil && player.mainWindow.videoView.isUninited
      }, then: continuation)
    }
  }

  private func completeQueueTermination() {
    let registered = PlayerCore.playerCores
    guard quitPlayers.count == 2, quitPlayers[0] !== quitPlayers[1], registered.count >= 2,
          quitPlayers.allSatisfy({ expected in registered.contains { $0 === expected } }),
          registered.allSatisfy({ $0.info.state == .shutDown }),
          quitPlayers.allSatisfy({ $0.nativePlaybackSession == nil && $0.nativePlaybackOutput == nil &&
            !$0.hasNativePlaybackQueue && $0.mpv.mpvRenderContext == nil &&
            $0.mainWindow.loaded && $0.mainWindow.videoView.isUninited }) else {
      fail("queue_all_registered_cores_shutdown"); return
    }
    record("queue_all_registered_cores_shutdown")
    terminal = true
    writeReport(complete: true, passed: true)
    print("NATIVE_APP_TEST_COMPLETE")
  }

  private func prepareActiveQuit() {
    // The first core stays loaded in compatibility, so this is a genuinely new core.
    let second = PlayerCore.newPlayerCore
    guard let first = player, first !== second else {
      fail("native_and_compatibility_ready_for_real_quit"); return
    }
    quitPlayers = [first, second]
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
            guard let layer = second.nativePlaybackOutput?.displayLayer else {
              self.fail("all_real_cores_shutdown_before_termination"); return
            }
            self.quitNativeLayer = layer
            self.awaitingQuit = true
            self.quitRequestedAt = ProcessInfo.processInfo.systemUptime
            self.reportShutdownState(stage: "before_terminate")
            self.writeReport(complete: false, passed: false)
            Self.performTerminationFromRunLoop {
              guard !self.terminal, self.awaitingQuit else { return }
              NSApp.terminate(nil)
            }
          }
        }
      }
    }
  }

  private static func performTerminationFromRunLoop(_ termination: @escaping () -> Void) {
    // terminateLater runs AppKit's nested termination loop. Entering it from a
    // main GCD block starves the main-queue shutdown completions it must await.
    // Match the production mpv-initiated quit path without pre-closing any core.
    RunLoop.main.perform(inModes: [.common], block: termination)
  }

  private func reportShutdownState(stage: String) {
    let registered = PlayerCore.playerCores
    let elapsed = quitRequestedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? -1
    print("NATIVE_APP_TEST_QUIT: stage=\(stage) elapsed=\(elapsed) expected=\(quitPlayers.count) registered=\(registered.count) nativeLayerDetached=\(quitNativeLayer?.superlayer == nil)")
    for (index, core) in registered.enumerated() {
      let expected = quitPlayers.firstIndex { $0 === core } ?? -1
      let notices = shutdownNotifications[ObjectIdentifier(core), default: 0]
      let windowLoaded = core.mainWindow.loaded
      let videoUninited = windowLoaded ? core.mainWindow.videoView.isUninited : false
      // A headless mpv handle is detached after mpvHasShutdown returns. Its
      // pointer is diagnostic, not a substitute for genuine shutdown state.
      print("NATIVE_APP_TEST_QUIT_CORE: index=\(index) expected=\(expected) state=\(core.info.state) notices=\(notices) nativeSession=\(core.nativePlaybackSession != nil) nativeOutput=\(core.nativePlaybackOutput != nil) glContext=\(core.mpv.mpvRenderContext != nil) windowLoaded=\(windowLoaded) videoUninited=\(videoUninited) mpvHandle=\(core.mpv.mpv != nil)")
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

  private func wait(_ label: String, timeout: Double = 12, recordSuccess: Bool = true, until condition: @escaping () -> Bool,
                    then continuation: @escaping () -> Void) {
    pollRevision += 1
    let request = pollRevision
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    func poll() {
      guard !terminal, request == pollRevision else { return }
      if condition() {
        if recordSuccess { record(label) }
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
    if label.hasPrefix("preview_") { logPreviewState() }
    if label.hasPrefix("handoff_") { logHandoffElapsed(label) }
    checks.append(["label": label, "passed": true])
    print("NATIVE_APP_TEST_PASS: \(label)")
    logTotalElapsed(label)
    writeReport(complete: false, passed: false)
  }

  private func fail(_ label: String) {
    guard !terminal else { return }
    if label.hasPrefix("preview_") { logPreviewState() }
    if label.hasPrefix("handoff_") { logHandoffElapsed(label) }
    terminal = true
    checks.append(["label": label, "passed": false])
    writeReport(complete: true, passed: false)
    fputs("NATIVE_APP_TEST_FAIL: \(label)\n", stderr)
    logTotalElapsed(label)
    exit(1)
  }

  private func logPreviewState() {
    guard let player else { print("NATIVE_APP_PREVIEW_STATE: player=unavailable"); return }
    guard let main = player.mainWindow else { print("NATIVE_APP_PREVIEW_STATE: window=unavailable"); return }
    let range = player.videoToolsLoopRange
    // Main-owned cached state is diagnostic only. Worker-clock assertions are
    // still made separately, without reading worker-owned fields from AppKit.
    print("NATIVE_APP_PREVIEW_STATE: native=\(player.isUsingNativePlayback) preview=\(player.nativePreviewInProgress) phase=\(String(describing: player.info.state)) cachedPosition=\(player.playbackPosition ?? -1) start=\(range?.start ?? -1) end=\(range?.end ?? -1) paused=\(player.playbackIsPaused) sidebarHidden=\(main.sidebarAutoHidden) gl=\(main.videoView.hasInitializedOpenGL)")
    let settings = main.quickSettingView
    let panels = settings.children.compactMap { $0 as? VideoToolsViewController }
    let attached = panels.contains { $0.isViewLoaded && $0.view.window === main.window }
    print("NATIVE_APP_PREVIEW_PANEL: windowLoaded=\(main.loaded) windowVisible=\(main.window?.isVisible == true) sidebar=\(String(describing: main.sideBarStatus)) sidebarVisible=\(main.isSidebarVisible) settingsLoaded=\(settings.isViewLoaded) tab=\(String(describing: settings.currentTab)) panelCount=\(panels.count) panelAttached=\(attached) controlsReady=\(previewControls(player) != nil)")
  }

  private func logHandoffElapsed(_ label: String) {
    let elapsed = handoffStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? -1
    print("NATIVE_APP_HANDOFF_ELAPSED: stage=\(label) seconds=\(elapsed)")
  }

  private func logTotalElapsed(_ label: String) {
    let elapsed = startedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? -1
    print("NATIVE_APP_TEST_ELAPSED: stage=\(label) seconds=\(elapsed)")
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
