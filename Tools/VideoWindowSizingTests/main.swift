import Cocoa

var checks = 0
func check(_ result: @autoclosure () -> Bool, _ message: String) {
  checks += 1
  guard result() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}
func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }
func size(_ actual: NSSize, _ width: CGFloat, _ height: CGFloat, _ message: String) {
  check(close(actual.width, width) && close(actual.height, height), "\(message): \(actual)")
}
func inside(_ frame: NSRect, _ bounds: NSRect, _ message: String) {
  check(frame.minX >= bounds.minX - 0.001 && frame.maxX <= bounds.maxX + 0.001
        && frame.minY >= bounds.minY - 0.001 && frame.maxY <= bounds.maxY + 0.001, message)
}

let suite = "io.github.SeanLi-Coder.WindowSizingTests.\(UUID().uuidString)"
Preference.ud = UserDefaults(suiteName: suite)!
defer { Preference.ud.removePersistentDomain(forName: suite) }
func registerDefaults() {
  Preference.ud.register(defaults: Dictionary(uniqueKeysWithValues: Preference.defaultPreference.map { ($0.key.rawValue, $0.value) }))
}
func reset() {
  Preference.ud.removePersistentDomain(forName: suite)
  registerDefaults()
}
func configure(_ key: Preference.Key, _ value: Any) { Preference.ud.set(value, forKey: key.rawValue) }
func controller(width: Int = 1280, height: Int = 720,
                screen: NSScreen = NSScreen(NSRect(x: 0, y: 24, width: 2000, height: 1400), scale: 2)) -> MainWindowController {
  let result = MainWindowController()
  result.destinationScreen = screen
  NSScreen.main = screen
  result.window = RecordingWindow(frame: NSRect(x: 100, y: 100, width: 640, height: 360), screen: screen)
  result.player.info.displayWidth = width
  result.player.info.displayHeight = height
  result.player.info.videoWidth = width
  return result
}

reset()
check(!Preference.bool(for: .usePhysicalResolution), "Default dimensions are window points, not Retina-divided pixels")
check((Preference.enum(for: .resizeWindowTiming) as Preference.ResizeWindowTiming) == .always,
      "Default file changes adapt to every video's dimensions")
check((Preference.enum(for: .resizeWindowOption) as Preference.ResizeWindowOption) == .videoSize10,
      "The default size multiplier is 1x")

// Default registration upgrades users who never saved these settings. It must
// not overwrite a persistent choice, including a legacy explicit true value.
Preference.ud.register(defaults: ["usePhysicalResolution": true, "resizeWindowTiming": 1])
registerDefaults()
check(!Preference.bool(for: .usePhysicalResolution) && Preference.integer(for: .resizeWindowTiming) == 0,
      "New registered defaults replace old registered defaults without a destructive migration")
configure(.usePhysicalResolution, true)
configure(.resizeWindowTiming, Preference.ResizeWindowTiming.never.rawValue)
configure(.resizeWindowOption, Preference.ResizeWindowOption.videoSize05.rawValue)
registerDefaults()
check(Preference.bool(for: .usePhysicalResolution)
      && Preference.integer(for: .resizeWindowTiming) == Preference.ResizeWindowTiming.never.rawValue
      && Preference.integer(for: .resizeWindowOption) == Preference.ResizeWindowOption.videoSize05.rawValue,
      "Explicit physical-pixel, never-resize and half-size preferences survive an upgrade")
reset()

for scale: CGFloat in [1, 2] {
  let screen = NSScreen(NSRect(x: 0, y: 24, width: 2000, height: 1400), scale: scale)
  let item = controller(screen: screen)
  item.handleVideoSizeChange()
  size(item.window!.frame.size, 1280, 720, "720p opens at its display dimensions on a \(scale)x display")
  size(item.window!.aspectRatio, 1280, 720, "Window uses the display aspect")
  size(item.pip.aspectRatio, 1280, 720, "PiP receives the display aspect")
  inside(item.window!.frame, screen.visibleFrame, "Open window remains inside the visible screen")
  check(!item.shouldApplyInitialWindowSize && item.isVideoLoaded, "Initial sizing and thumbnail lifecycle complete")
  check(item.player.generatedThumbnails == 1 && item.playTimeUpdates == 1 && item.player.events.frames.count == 1,
        "Existing load notifications and thumbnails remain wired")
  check(item.player.mpv.writes.allSatisfy { $0.0 == MPVProperty.windowScale }, "Opening does not mutate playback properties")
}

let laptop = NSScreen(NSRect(x: 0, y: 72, width: 1728, height: 1007), scale: 2)
for source in [(1920, 1080), (2560, 1440), (3840, 2160), (7680, 4320)] {
  let item = controller(width: source.0, height: source.1, screen: laptop)
  item.handleVideoSizeChange()
  size(item.window!.frame.size, 1728, 972, "Oversize \(source) video fits the laptop, preserving aspect")
  inside(item.window!.frame, laptop.visibleFrame, "Video avoids the menu bar and Dock")
}

let portraitScreen = NSScreen(NSRect(x: -2000, y: 48, width: 1800, height: 1000), scale: 1)
for rotation in [90, 270] {
  let item = controller(width: 1920, height: 1080, screen: portraitScreen)
  item.player.mpv.integers[MPVProperty.videoParamsRotate] = rotation
  item.handleVideoSizeChange()
  size(item.window!.frame.size, 562.5, 1000, "\(rotation)-degree video uses portrait display dimensions")
  size(item.window!.aspectRatio, 1080, 1920, "Orientation changes the window aspect, not only its content")
  inside(item.window!.frame, portraitScreen.visibleFrame, "Negative-origin monitor coordinates are respected")
}
let sar = controller(width: 1024, height: 576)
sar.player.info.videoWidth = 720
sar.handleVideoSizeChange()
size(sar.window!.frame.size, 1024, 576, "Anamorphic video uses mpv display width, not coded pixel width")

let cancelledRotation = controller(width: 1280, height: 720)
cancelledRotation.player.mpv.integers[MPVProperty.videoParamsRotate] = 90
cancelledRotation.player.mpv.integers[MPVOption.Video.videoRotate] = 90
cancelledRotation.handleVideoSizeChange()
size(cancelledRotation.window!.frame.size, 1280, 720, "Effective rotation does not swap dimensions twice")

let next = controller()
next.handleVideoSizeChange()
next.player.info.justOpenedFile = false
next.player.info.displayWidth = 1920
next.player.info.displayHeight = 1080
next.handleVideoSizeChange()
size(next.window!.frame.size, 1920, 1080, "Playlist navigation adapts to the newly opened video's dimensions")
check(next.player.generatedThumbnails == 1, "Repeated resize notifications do not regenerate initial thumbnails")

configure(.resizeWindowTiming, Preference.ResizeWindowTiming.onlyWhenOpen.rawValue)
let preserved = controller(width: 1920, height: 1080)
preserved.shouldApplyInitialWindowSize = false
preserved.player.info.justOpenedFile = false
preserved.handleVideoSizeChange()
size(preserved.window!.frame.size, 640, 360, "Explicit only-when-open preserves width during playlist navigation")
configure(.resizeWindowTiming, Preference.ResizeWindowTiming.never.rawValue)
preserved.player.info.justOpenedFile = true
preserved.handleVideoSizeChange()
size(preserved.window!.frame.size, 640, 360, "Explicit never-resize preserves the user's existing width")
reset()

configure(.usePhysicalResolution, true)
let physical = controller(width: 1920, height: 1080)
physical.handleVideoSizeChange()
size(physical.window!.frame.size, 960, 540, "Explicit physical resolution remains 1:1 on Retina")
let moved = controller(width: 1280, height: 720,
                       screen: NSScreen(NSRect(x: 1920, y: 24, width: 1920, height: 1200), scale: 1))
moved.window!.screen = laptop
moved.handleVideoSizeChange()
size(moved.window!.frame.size, 1280, 720, "Physical sizing uses the destination screen's scale, not the previous screen")
inside(moved.window!.frame, moved.destinationScreen.visibleFrame, "New windows move completely onto the selected screen")
reset()

configure(.resizeWindowOption, Preference.ResizeWindowOption.videoSize05.rawValue)
let half = controller(width: 1920, height: 1080)
half.handleVideoSizeChange()
size(half.window!.frame.size, 960, 540, "Explicit half-size remains available")
configure(.resizeWindowOption, Preference.ResizeWindowOption.videoSize20.rawValue)
let double = controller(width: 640, height: 360)
double.handleVideoSizeChange()
size(double.window!.frame.size, 1280, 720, "Explicit double-size remains available")
configure(.resizeWindowOption, Preference.ResizeWindowOption.fitScreen.rawValue)
let fit = controller(screen: laptop)
fit.handleVideoSizeChange()
size(fit.window!.frame.size, 1728, 972, "Explicit fit-screen enlarges a smaller video to the screen")
reset()

let geometry = controller()
geometry.cachedGeometry = GeometryDef(w: "800", x: "100", xSign: "+", y: "100", ySign: "+")
geometry.handleVideoSizeChange()
size(geometry.window!.frame.size, 800, 450, "Explicit initial geometry overrides default source size")
check(geometry.window!.frame.origin == NSPoint(x: 100, y: 124), "Explicit geometry position respects the screen origin")

let fullscreen = controller(width: 3840, height: 2160, screen: laptop)
fullscreen.fsState = FullScreenState(isFullscreen: true, priorWindowedFrame: fullscreen.window!.frame)
let fullscreenFrame = fullscreen.window!.frame
fullscreen.handleVideoSizeChange()
check(fullscreen.window!.frames.isEmpty && fullscreen.window!.frame == fullscreenFrame,
      "Opening another video never exits or resizes the active fullscreen window")
size(fullscreen.fsState.priorWindowedFrame!.size, 1728, 972, "Leaving fullscreen restores a correctly fitted source-sized frame")
check(fullscreen.player.mpv.writes.isEmpty, "Fullscreen bookkeeping does not issue a window-scale command")
let fullscreenGeometry = controller(width: 3840, height: 2160, screen: laptop)
fullscreenGeometry.fsState.isFullscreen = true
fullscreenGeometry.cachedGeometry = GeometryDef(w: "6000", x: "-500", xSign: "+")
fullscreenGeometry.handleVideoSizeChange()
inside(fullscreenGeometry.fsState.priorWindowedFrame!, laptop.visibleFrame,
       "Fullscreen initial geometry cannot leave an oversized restore frame offscreen")

for dimensions in [(320, 240), (3840, 100), (100, 3840)] {
  let item = controller(width: dimensions.0, height: dimensions.1, screen: laptop)
  item.handleVideoSizeChange()
  let frame = item.window!.frame
  inside(frame, laptop.visibleFrame, "Minimum control size cannot force extreme-aspect media offscreen")
  check(close(frame.width / frame.height, CGFloat(dimensions.0) / CGFloat(dimensions.1)), "Extreme aspect ratio is preserved")
}
let audio = controller(width: 0, height: 0)
audio.handleVideoSizeChange()
size(audio.window!.frame.size, 640, 360, "Audio-only files retain the production fallback size")

let scale = controller(width: 3840, height: 2160, screen: laptop)
scale.window!.frame = NSRect(x: 40, y: 100, width: 400, height: 400)
scale.setWindowScale(1)
size(scale.window!.frame.size, 1728, 972, "1x scale fits the requested source size, not an old small square window")
inside(scale.window!.frame, laptop.visibleFrame, "Manual scale stays inside the screen")
configure(.usePhysicalResolution, true)
let manualPhysical = controller(width: 1280, height: 720)
manualPhysical.setWindowScale(1)
size(manualPhysical.window!.frame.size, 640, 360, "Manual scale also respects explicit physical pixels")
reset()

for invalid in [Double.nan, Double.infinity, -Double.infinity, 0, -1, Double.greatestFiniteMagnitude] {
  let item = controller()
  item.setWindowScale(invalid)
  check(item.window!.frames.isEmpty, "Invalid window scale is ignored safely: \(invalid)")
}
let fullscreenScale = controller()
fullscreenScale.fsState.isFullscreen = true
fullscreenScale.setWindowScale(2)
check(fullscreenScale.window!.frames.isEmpty, "Manual window scale never changes fullscreen")

let invalidDisplay = controller(width: -1, height: 720)
invalidDisplay.handleVideoSizeChange()
invalidDisplay.setWindowScale(1)
check(invalidDisplay.window!.frames.isEmpty, "Invalid video dimensions do not reach AppKit window sizing")
let missingWindow = controller()
missingWindow.window = nil
missingWindow.handleVideoSizeChange()
missingWindow.setWindowScale(1)
check(missingWindow.player.events.frames.isEmpty, "Absent windows are ignored")

print("PASS: \(checks) production video window sizing checks")
