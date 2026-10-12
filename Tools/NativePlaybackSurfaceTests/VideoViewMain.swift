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
    let replacement = NativeSampleBufferOutput()
    player.nativePlaybackOutput = replacement
    check(view.configurePlaybackSurface(), "Native session layer can be replaced")
    check(output.displayLayer.superlayer == nil, "Old output is detached without shutting down on main")
    check(view.nativeSurface?.displayLayer === replacement.displayLayer, "Replacement output is installed")
    player.isUsingNativePlayback = false
    check(view.configurePlaybackSurface(), "Explicit compatibility fallback installs GL boundary")
    check(!view.isUsingNativeSurface && view.nativeSurface == nil, "Fallback removes native view")
    check(replacement.displayLayer.superlayer == nil, "Fallback detaches the native output")
    check(ViewLayer.constructions == 1 && view.hasInitializedOpenGL, "Compatibility layer is created exactly once after fallback")
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
    window.orderOut(nil)
    window.close()
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "native-view-test-shutdown")
    for candidate in [output, replacement, nativeOnlyPlayer.nativePlaybackOutput!] {
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
