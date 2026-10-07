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
var playbackRestarts = 0
var position: Double?
func pump(_ seconds: Double) {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end {
    while let event = mpv_wait_event(player.mpv.mpv, 0), event.pointee.event_id != MPV_EVENT_NONE {
      if event.pointee.event_id == MPV_EVENT_FILE_LOADED { loadedFiles += 1 }
      if event.pointee.event_id == MPV_EVENT_PLAYBACK_RESTART { playbackRestarts += 1 }
      if event.pointee.event_id == MPV_EVENT_PROPERTY_CHANGE,
         let property = event.pointee.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
         String(cString: property.name) == "time-pos", property.format == MPV_FORMAT_DOUBLE,
         let value = property.data?.assumingMemoryBound(to: Double.self).pointee {
        position = value
      }
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
  let initialRestarts = playbackRestarts
  position = nil
  player.mpv.command(["loadfile", media])
  player.mpv.setString("pause", "no")
  let loadDeadline = Date().addingTimeInterval(3)
  while loadedFiles <= index && Date() < loadDeadline { pump(0.01) }
  precondition(loadedFiles == index + 1, "Every reopened file must complete loading before its close probe")
  let initialFrames = ObservedLayer.frames
  let initialPictures = ObservedLayer.pictureFrames
  let initialPosition = position ?? 0
  let readinessStarted = Date()
  let frameDeadline = Date().addingTimeInterval(8)
  while (ObservedLayer.pictureFrames < initialPictures + 2 || playbackRestarts <= initialRestarts ||
         (position ?? 0) <= initialPosition + 0.01),
        Date() < frameDeadline { pump(0.01) }
  let frameDelta = ObservedLayer.frames - initialFrames
  let pictureDelta = ObservedLayer.pictureFrames - initialPictures
  let readyAfter = Date().timeIntervalSince(readinessStarted)
  print("READY: \(index), loaded=\(loadedFiles), frames=\(frameDelta), pictures=\(pictureDelta), restarts=\(playbackRestarts - initialRestarts), position=\(position ?? -1), wait=\(String(format: "%.3f", readyAfter))s, canDraw=\(ObservedLayer.acceptedReadinessChecks)/\(ObservedLayer.readinessChecks), visible=\(window.isVisible), bounds=\(video.videoLayer.bounds)")
  fflush(stdout)
  precondition(frameDelta >= 2 && pictureDelta >= 2 && playbackRestarts > initialRestarts &&
               (position ?? 0) > initialPosition + 0.01,
               "Each reopened media must display two decoded pictures and advance playback")
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
precondition(ObservedLayer.pictureFrames >= 60, "Every close must follow two verified video pictures")
if let requested = ProcessInfo.processInfo.environment["CLOSE_TEST_HWDEC"], requested != "no" {
  precondition(decoders.contains(requested), "The requested hardware decoder must actually be observed")
}
print("PASS: Close and reopen stress completed, loaded=\(loadedFiles), rendered=\(ObservedLayer.frames), pictures=\(ObservedLayer.pictureFrames), decoders=\(decoders.sorted())")
