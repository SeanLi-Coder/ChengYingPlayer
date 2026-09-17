import Cocoa

@main
enum RoutingTests {
  static func main() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
      guard value() else { fatalError("FAIL: \(message)") }
      checks += 1
      print("PASS: \(message)")
    }
    func window() -> NSWindow {
      NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 640, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
    }
    let video = PlayerWindowController(window: window())
    let image = ImageViewerWindowController(window: window())
    let unrelated = NSWindowController(window: window())
    let first = URL(fileURLWithPath: "/tmp/first-video.mp4")
    let second = URL(fileURLWithPath: "/tmp/second-video.mp4")
    let picture = URL(fileURLWithPath: "/tmp/picture.png")
    video.player.info.currentURL = first
    image.selectedURL = picture
    let coordinator = MediaInfoCoordinator()
    let panel = MediaInfoWindowController.latest!
    let center = NotificationCenter.default
    check(coordinator.candidate(keyWindow: image.window, mainWindow: video.window) === image.window,
      "A foreground image never routes to a background video")
    check(coordinator.candidate(keyWindow: video.window, mainWindow: image.window) === video.window,
      "A foreground video takes priority over a background image")
    check(coordinator.candidate(keyWindow: unrelated.window, mainWindow: video.window) == nil,
      "Settings and non-media windows never expose an unrelated file")
    check(coordinator.candidate(keyWindow: nil, mainWindow: image.window) === image.window,
      "The main media window is used only when no key window exists")
    coordinator.showMediaInfo(video.window!.contentView)
    check(panel.currentURL == first && panel.presentations == 1,
      "A video info button opens information for its own source")
    check(coordinator.candidate(keyWindow: panel.window, mainWindow: unrelated.window) === video.window,
      "The information window retains its actual media owner")
    video.player.info.currentURL = second
    center.post(name: .chengyingMediaSourceChanged, object: video.player)
    check(panel.currentURL == second, "Video changes refresh without waiting for playback decoding")
    let previous = panel.refreshes
    center.post(name: .chengyingImageSourceChanged, object: image)
    check(panel.currentURL == second && panel.refreshes == previous,
      "Background image changes cannot replace the visible video information")
    video.player.info.currentURL = nil
    center.post(name: .iinaPlayerStopped, object: video.player)
    check(panel.currentURL == nil, "Stopping clears stale video metadata")
    video.player.info.currentURL = URL(string: "https://example.invalid/private?token=secret")
    coordinator.showMediaInfo(video.window!.contentView)
    check(panel.presentations == 1, "Network media is never passed to the local metadata reader")
    coordinator.showMediaInfo(image.window!.contentView)
    check(panel.currentURL == picture, "An image info button opens its own image")
    image.selectedURL = URL(fileURLWithPath: "/tmp/next.gif")
    center.post(name: .chengyingImageSourceChanged, object: image)
    check(panel.currentURL == image.selectedURL, "Browsing images refreshes the displayed source")
    center.post(name: NSWindow.willCloseNotification, object: video.window)
    check(panel.closes == 0, "Closing a background video does not close image information")
    center.post(name: NSWindow.willCloseNotification, object: image.window)
    check(panel.closes == 1 && panel.currentURL == nil, "Closing the media owner closes and clears its panel")
    coordinator.close()
    print("Media information routing checks passed: \(checks)")
  }
}
