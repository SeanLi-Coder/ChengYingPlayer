import Cocoa

let hardwareRequested = (ProcessInfo.processInfo.environment["CLOSE_TEST_HWDEC"] ?? "no") != "no"
let forceSoftwareGL = ProcessInfo.processInfo.environment["CHENGYING_TEST_SOFTWARE_GL"] == "1"
if hardwareRequested && forceSoftwareGL {
  fputs("FAIL: Hardware decoding cannot be verified with forced software OpenGL\n", stderr)
  exit(1)
}

NSApplication.shared.setActivationPolicy(.accessory)
let player = PlayerCore()
let video = VideoView(player: player)
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 360),
                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.title = "Player Close Regression"
window.contentView = video
player.mpv.startRendering(layer: video.videoLayer)

var loadedFiles = 0
func pump(_ seconds: Double) {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end {
    while let event = mpv_wait_event(player.mpv.mpv, 0), event.pointee.event_id != MPV_EVENT_NONE {
      if event.pointee.event_id == MPV_EVENT_FILE_LOADED { loadedFiles += 1 }
      if event.pointee.event_id == MPV_EVENT_END_FILE,
         let result = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
        precondition(result.reason != MPV_END_FILE_REASON_ERROR, "The generated media must decode successfully")
      }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
  }
}

final class CloseDelegate: NSObject, NSWindowDelegate {
  let player: PlayerCore
  var preview = false
  init(player: PlayerCore) { self.player = player }
  func windowWillClose(_ notification: Notification) {
    if preview {
      player.mpv.setString("ab-loop-count", "0")
      player.mpv.setString("ab-loop-a", "no")
      player.mpv.setString("ab-loop-b", "no")
      player.mpv.setString("video-rotate", "0")
      player.mpv.command(["seek", "0.5", "absolute+exact"])
      player.mpv.setString("pause", "no")
    }
    player.mpv.setString("pause", "yes")
    player.mpv.command(["stop"])
  }
}
let delegate = CloseDelegate(player: player)
window.delegate = delegate
let media = CommandLine.arguments[1]
var decoders = Set<String>()
for index in 0..<30 {
  window.orderFront(nil)
  delegate.preview = index % 2 == 0
  player.mpv.command(["loadfile", media])
  player.mpv.setString("pause", "no")
  let loadDeadline = Date().addingTimeInterval(3)
  while loadedFiles <= index && Date() < loadDeadline { pump(0.01) }
  precondition(loadedFiles == index + 1, "Every reopened file must complete loading before its close probe")
  pump(0.1)
  if let decoder = player.mpv.getString("hwdec-current") { decoders.insert(decoder) }
  if delegate.preview {
    player.mpv.setString("video-rotate", "90")
    player.mpv.setString("ab-loop-a", "0.25")
    player.mpv.setString("ab-loop-b", "1.25")
    player.mpv.setString("ab-loop-count", "inf")
  }
  print("CLOSE: \(index), preview=\(delegate.preview)")
  fflush(stdout)
  window.close()
  pump(0.03)
}
player.mpv.finish(view: video)
precondition(ObservedLayer.frames > 30, "The real OpenGL layer must render frames")
if let requested = ProcessInfo.processInfo.environment["CLOSE_TEST_HWDEC"], requested != "no" {
  precondition(decoders.contains(requested), "The requested hardware decoder must actually be observed")
}
print("PASS: Close and reopen stress completed, loaded=\(loadedFiles), rendered=\(ObservedLayer.frames), decoders=\(decoders.sorted())")
