import AppKit
import AVFoundation

@main struct VideoViewTests {
  static var passed = 0
  static var failed = 0
  static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { passed += 1; print("PASS: \(label)") }
    else { failed += 1; print("FAIL: \(label)") }
  }
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let player = PlayerCore()
    let view = VideoView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), player: player)
    player.mainWindow.videoView = view
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    player.mainWindow.window = window
    window.contentView = view
    window.orderFront(nil)
    view.layoutSubtreeIfNeeded()
    check(view.isUsingNativeSurface && !view.hasInitializedOpenGL, "Native VideoView starts without GL")
    check(ViewLayer.constructions == 0, "Native construction never invokes compatibility layer initializer")
    check(!(view.layer is ViewLayer), "Native host is an ordinary layer")
    check(view.nativeSurface?.displayLayer === player.nativePlaybackOutput?.displayLayer, "Production output attaches to production surface")
    check(view.nativeSurface?.superview === view, "Surface is owned by VideoView")
    check(view.configurePlaybackSurface(), "Native configuration is idempotent")
    view.startDisplayLink()
    view.updateDisplayLink()
    view.displayActive()
    view.displayIdle()
    view.refreshEdrMode()
    check(view.requestEdrMode() == false, "Native HDR probe cannot read idle MPV")
    check(view.link == nil && view.currentDisplay == nil, "Native lifecycle never starts CVDisplayLink")
    check(player.mpv.touches == 0, "Native lifecycle does not touch MPV")
    check(view.updateNativeViewport(zoom: 2, pan: CGPoint(x: 20, y: 30)), "Native viewport routes to surface")
    check(view.nativeSurface?.zoom == 2 && view.nativeSurface?.pan == CGPoint(x: 20, y: 30), "Viewport units remain linear and point-based")
    check(!view.updateNativeViewport(zoom: .nan, pan: .zero), "Invalid zoom is rejected")
    view.playbackInLiveResize = true
    check(view.playbackInLiveResize, "Native live resize uses non-GL state")
    view.setFrameSize(CGSize(width: 620, height: 400))
    view.forcePlaybackRedraw()
    check(view.nativeSurface?.frame == view.bounds, "Resize tracks the full video viewport")
    view.updatePlaybackContentsScale()
    view.playbackInLiveResize = false
    check(!view.playbackInLiveResize && ViewLayer.constructions == 0, "Live resize and backing changes do not create GL")
    let output = player.nativePlaybackOutput!
    check(view.nativeSurface!.setVideoGeometry(codedSize: CGSize(width: 720, height: 576),
      pixelAspectRatio: 16.0 / 15, rotationDegrees: 90), "Native viewport uses a rotated SAR-corrected source")
    check(view.updateNativeViewport(scale: 2, normalizedPan: CGPoint(x: 0.1, y: -0.2)),
      "Production VideoView routes normalized viewport without initializing GL")
    check(view.nativeSurface!.pan.x > 0 && view.nativeSurface!.pan.y > 0,
      "Normalized pan reaches upward-positive actual surface points")
    let replacement = NativeSampleBufferOutput()
    player.nativePlaybackOutput = replacement
    check(view.configurePlaybackSurface(), "Native session layer can be replaced")
    check(output.displayLayer.superlayer == nil, "Old output is detached without shutting down on main")
    check(view.nativeSurface?.displayLayer === replacement.displayLayer, "Replacement output is installed")
    check(view.nativeSurface?.zoom == 1 && view.nativeSurface?.pan == .zero && view.nativeSurface?.geometry == nil,
      "New output identity resets prior normalized viewport and source geometry")
    check(view.nativeSurface!.setVideoGeometry(codedSize: CGSize(width: 1920, height: 1080)),
      "Replacement output accepts independent source geometry")
    let replacementGeometry = view.nativeSurface?.geometry
    check(!view.detachNativePlaybackOutput(output), "A stale output cannot detach the current session")
    check(view.nativeSurface?.displayLayer === replacement.displayLayer && replacement.displayLayer.superlayer != nil &&
      view.nativeSurface?.geometry == replacementGeometry,
      "Rejected old-owner detachment preserves the current layer and geometry")
    view.setFrameSize(CGSize(width: 400, height: 300))
    view.forcePlaybackRedraw()
    check(view.nativeSurface?.pan == .zero && view.nativeSurface?.zoom == 1,
      "Replacement resize cannot resurrect the old media normalized pan")
    let retiring = RetirementTransportBoundary(output: replacement)
    player.nativeTransport = retiring
    player.nativeLoopA = 0; player.nativeLoopB = 1
    var retired = 0
    player.testRetire { retired += 1 }
    check(replacement.displayLayer.superlayer == nil && view.nativeSurface?.displayLayer == nil,
      "Core retirement detaches its output before asynchronous shutdown completes")
    check(player.nativeRetiring && player.nativeTransport === retiring && retired == 0,
      "Presentation detachment does not complete or release the retiring session early")
    check(retiring.session.shutdownCalls == 1 && retiring.onSnapshot == nil,
      "Retirement still disables snapshots and starts exactly one asynchronous shutdown")
    check(view.isUsingNativeSurface && !view.isUninited && !view.hasInitializedOpenGL,
      "Retirement leaves a reusable native view without switching to GL")
    player.testRetire { retired += 10 }
    check(retiring.session.shutdownCalls == 1 && retired == 0,
      "Repeated retirement updates its continuation without a second worker shutdown")
    retiring.session.finish()
    check(retired == 10 && player.nativeTransport == nil && !player.nativeRetiring && !player.nativeReady,
      "The latest retirement continuation runs only after asynchronous shutdown")
    check(player.info.state == .idle && replacement.displayLayer.superlayer == nil,
      "Idle after retirement has no retained output layer")
    check(!view.detachNativePlaybackOutput(replacement), "Repeated detachment of a retired output is a harmless no-op")
    player.isUsingNativePlayback = false
    view.playbackInLiveResize = true
    view.updatePlaybackContentsScale()
    view.forcePlaybackRedraw()
    view.startDisplayLink()
    view.displayActive()
    view.playbackInLiveResize = false
    check(view.isUsingNativeSurface && ViewLayer.constructions == 0 && player.mpv.touches == 0 && view.link == nil,
      "Idle redraw and resize remain native and never initialize the compatibility renderer")
    player.isUsingNativePlayback = true
    let reopened = NativeSampleBufferOutput()
    player.nativePlaybackOutput = reopened
    check(view.configurePlaybackSurface() && view.nativeSurface?.displayLayer === reopened.displayLayer,
      "The same stopped view accepts a new native output without uninit")
    check(view.nativeSurface?.geometry == nil && view.nativeSurface?.zoom == 1 && view.nativeSurface?.pan == .zero,
      "Reopening after retirement begins with independent geometry and viewport")
    check(!view.detachNativePlaybackOutput(replacement) && view.nativeSurface?.displayLayer === reopened.displayLayer,
      "A late old-output detach cannot remove the newly attached session")
    player.isUsingNativePlayback = false
    check(view.configurePlaybackSurface(), "Explicit compatibility fallback installs GL boundary")
    check(!view.isUsingNativeSurface && view.nativeSurface == nil, "Fallback removes native view")
    check(reopened.displayLayer.superlayer == nil, "Fallback detaches the native output")
    check(ViewLayer.constructions == 1 && view.hasInitializedOpenGL, "Compatibility layer is created exactly once after fallback")
    check(!view.detachNativePlaybackOutput(reopened) && ViewLayer.constructions == 1,
      "A late native detach cannot alter the selected compatibility renderer")
    player.isUsingNativePlayback = true
    check(!view.configurePlaybackSurface(), "A core with initialized GL cannot reenter native mode")
    check(!view.isUsingNativeSurface, "Rejected mode switch leaves the active surface intact")
    player.isUsingNativePlayback = false
    view.uninit()
    let nativeOnlyPlayer = PlayerCore()
    let nativeOnly = VideoView(frame: .zero, player: nativeOnlyPlayer)
    nativeOnly.uninit()
    nativeOnly.uninit()
    check(nativeOnly.isUninited && nativeOnlyPlayer.mpv.touches == 0, "Native teardown is idempotent without GL locks or MPV calls")
    check(nativeOnlyPlayer.nativePlaybackOutput!.displayLayer.superlayer == nil, "Native teardown detaches presentation")
    check(!nativeOnly.configurePlaybackSurface(), "Closed view cannot reactivate")
    let unopenedPlayer = PlayerCore()
    unopenedPlayer.mainWindow.loaded = false
    let unopenedTransport = RetirementTransportBoundary(output: unopenedPlayer.nativePlaybackOutput!)
    unopenedPlayer.nativeTransport = unopenedTransport
    var unopenedFinished = false
    unopenedPlayer.testRetire { unopenedFinished = true }
    check(unopenedPlayer.mainWindow.videoView == nil && unopenedTransport.session.shutdownCalls == 1 && !unopenedFinished,
      "Retirement before window load does not materialize a view or skip worker shutdown")
    unopenedTransport.session.finish()
    check(unopenedFinished && unopenedPlayer.info.state == .idle,
      "A never-presented session still completes retirement normally")
    window.orderOut(nil)
    window.close()
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "native-view-test-shutdown")
    for candidate in [output, replacement, reopened, nativeOnlyPlayer.nativePlaybackOutput!, unopenedPlayer.nativePlaybackOutput!] {
      group.enter()
      queue.async { candidate.shutdown { group.leave() } }
    }
    var done = false
    group.notify(queue: .main) { done = true }
    let deadline = Date().addingTimeInterval(4)
    while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    check(done, "All real outputs shut down asynchronously")
    print("VideoView presentation boundary: \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
  }
}
