import Cocoa
import Darwin

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  checks += 1
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}
func near(_ first: Double, _ second: Double, tolerance: Double = 0.0001) -> Bool {
  abs(first - second) <= tolerance
}
func snapshot(_ context: String) -> ViewportLiveSnapshot {
  var result = ViewportLiveSnapshot()
  expect(viewport_live_snapshot(&result), "Read rendered pixels and playback state: \(context)")
  expect(result.window_unchanged, "Window origin and size remain unchanged: \(context)")
  expect(result.display_width == 3840 && result.display_height == 2160,
    "The source display dimensions used by app window-resize callbacks remain unchanged: \(context)")
  expect(near(result.window_scale, 1), "The separate window-scale property remains unchanged: \(context)")
  return result
}
let player = PlayerCore()
func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false) -> VideoToolsViewport {
  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
    timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
    isARepeat: repeatKey, keyCode: code)!
  guard let action = VideoToolsShortcuts.resolve(event, hasMedia: true, isTextInput: false),
        let result = player.videoToolsApplyViewportShortcut(action) else {
    fatalError("A production keyboard shortcut failed to reach the production viewport bridge")
  }
  expect(viewport_live_wait(0.1), "Render the changed production viewport")
  return result
}
func stable(_ sample: ViewportLiveSnapshot, relativeTo base: ViewportLiveSnapshot, _ context: String) {
  expect(sample.paused == base.paused, "Pause is unchanged: \(context)")
  expect(near(sample.speed, base.speed), "Speed is unchanged: \(context)")
  expect(near(sample.position, base.position, tolerance: 0.002), "Playback position is unchanged: \(context)")
}
func marker(_ sample: ViewportLiveSnapshot, like base: ViewportLiveSnapshot, x: Double = 0, y: Double = 0) {
  expect(near(sample.center_x, base.center_x + x, tolerance: 2), "The rendered horizontal marker position matches the requested direction")
  expect(near(sample.center_y, base.center_y + y, tolerance: 2), "The rendered vertical marker position matches the requested direction")
  expect(near(sample.width, base.width, tolerance: 2) && near(sample.height, base.height, tolerance: 2),
    "Panning preserves rendered marker dimensions")
}

guard CommandLine.arguments.count == 3 else {
  fputs("Usage: VideoViewportLiveTests GENERATED_MEDIA hardware|software\n", stderr)
  exit(2)
}
let hardware = CommandLine.arguments[2] == "hardware"
let opened = viewport_live_open(CommandLine.arguments[1], hardware)
if !opened && viewport_live_graphics_unavailable() { exit(77) }
expect(opened, "Open the real AppKit, OpenGL, and libmpv renderer")
defer { viewport_live_close() }
let original = snapshot("original fitted viewport")
expect(near(original.width, 80, tolerance: 2) && near(original.height, 40, tolerance: 2),
  "The 4K reference marker is fitted to 80 by 40 output pixels")
expect(near(original.center_x, 319.5, tolerance: 1) && near(original.center_y, 179.5, tolerance: 1),
  "The original fitted video is centered")
expect(viewport_live_set_speed(1.7) && viewport_live_seek(2), "Prepare a non-default paused playback state")
let base = snapshot("paused at two seconds and 1.7x")

let firstZoom = key(24)
expect(near(firstZoom.scale, 1.1), "The equal key changes the original display scale to 110 percent")
let zoomedOnce = snapshot("one equal key")
expect(near(zoomedOnce.width, base.width * 1.1, tolerance: 2) &&
       near(zoomedOnce.height, base.height * 1.1, tolerance: 2), "The actual video pixels grow by ten percent")
stable(zoomedOnce, relativeTo: base, "zoom in")
_ = key(27)
let reducedOnce = snapshot("one minus key")
marker(reducedOnce, like: base)
stable(reducedOnce, relativeTo: base, "zoom out")

for _ in 0..<10 { _ = key(24) }
let doubled = snapshot("two times the fitted scale")
expect(near(doubled.width, base.width * 2, tolerance: 2) &&
       near(doubled.height, base.height * 2, tolerance: 2), "The actual reference marker doubles in both dimensions")
let arrowFlags: NSEvent.ModifierFlags = [.command, .shift, .numericPad, .function]
_ = key(124, flags: arrowFlags)
let right = snapshot("Command Shift Right")
marker(right, like: doubled, x: 32)
stable(right, relativeTo: base, "pan right")
_ = key(123, flags: arrowFlags)
marker(snapshot("Command Shift Left returns to center"), like: doubled)
_ = key(125, flags: arrowFlags)
let down = snapshot("Command Shift Down")
marker(down, like: doubled, y: 18)
stable(down, relativeTo: base, "pan down")
_ = key(126, flags: arrowFlags)
marker(snapshot("Command Shift Up returns to center"), like: doubled)
_ = key(123, flags: arrowFlags)
marker(snapshot("negative horizontal displacement"), like: doubled, x: -32)
_ = key(126, flags: arrowFlags)
marker(snapshot("negative vertical displacement"), like: doubled, x: -32, y: -18)
_ = key(126, flags: arrowFlags, repeatKey: true)
marker(snapshot("held arrow key continues to pan"), like: doubled, x: -32, y: -36)

let reset = key(29, flags: [.command, .shift])
expect(near(reset.scale, 1) && near(reset.panX, 0) && near(reset.panY, 0), "The reset shortcut restores the original viewport")
let resetPixels = snapshot("reset shortcut")
marker(resetPixels, like: base)
stable(resetPixels, relativeTo: base, "reset shortcut")
for _ in 0..<5 { _ = key(27) }
let reduced = snapshot("half the fitted scale")
expect(near(reduced.width, base.width / 2, tolerance: 2) &&
       near(reduced.height, base.height / 2, tolerance: 2), "Minus can shrink video inside an unchanged window")
_ = key(124, flags: arrowFlags)
_ = key(126, flags: arrowFlags)
marker(snapshot("panning while smaller remains safely centered"), like: reduced)
stable(snapshot("shrunk viewport playback state"), relativeTo: base, "smaller viewport")

player.videoToolsResetViewport()
expect(viewport_live_wait(0.1), "Render the file-change reset bridge")
marker(snapshot("production file-change reset bridge"), like: base)
_ = key(24)
expect(viewport_live_set_paused(false) && viewport_live_wait(0.3), "Resume actual playback with a zoomed viewport")
let playing = snapshot("playing while zoomed")
expect(playing.paused == 0 && playing.position > base.position + 0.1,
  "Playback continues making progress while the video is zoomed")
_ = key(24)
let stillPlaying = snapshot("zoom changed during playback")
expect(stillPlaying.paused == 0 && near(stillPlaying.speed, 1.7) && stillPlaying.position > playing.position,
  "A zoom shortcut does not pause, alter speed, or rewind active playback")
expect(viewport_live_set_paused(true), "Pause before the post-zoom seek check")
expect(viewport_live_seek(3), "Seek remains available after zooming and panning")
let sought = snapshot("seek after viewport changes")
expect(near(sought.position, 3, tolerance: 0.05) && near(sought.zoom, log2(1.2)),
  "An explicit seek changes only playback time and retains the viewing transform")
let allowedWrites = Set([MPVOption.Video.videoZoom, MPVOption.Video.videoPanX, MPVOption.Video.videoPanY])
expect(!player.mpv.writes.isEmpty && Set(player.mpv.writes) == allowedWrites,
  "Production viewport actions write only the three presentation properties")
expect(sought.frames > original.frames + 15, "Actual OpenGL output changed repeatedly throughout the test")
print("Video viewport live tests passed: \(checks) checks; \(sought.frames) actual rendered frames; \(hardware ? "VideoToolbox" : "software") decoding.")
