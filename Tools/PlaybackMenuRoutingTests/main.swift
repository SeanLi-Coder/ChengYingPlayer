import AppKit

enum Logger {
  enum Level { case error }
  static func log(_ message: String, level: Level) {}
}
enum OSD { case aspect(String) }
enum Command { case cycle }
final class MPVBoundary {
  var commands: [[String]] = []
  func command(_ name: Command, args: [String]) { commands.append(args) }
}
final class PlayerBoundary {
  var isUsingNativePlayback = false
  var pending: (() -> Void)?
  let mpv = MPVBoundary()
  var aspects: [String] = []
  var rates: [Double] = []
  var volumes: [Double] = []
  var currentPlaybackSpeed = 1.5
  var playbackVolume = 30.0
  func requireMPVCompatibility(reason: String, completion: @escaping () -> Void) { pending = completion }
  func setVideoAspect(_ aspect: String) { aspects.append(aspect) }
  func sendOSD(_ message: OSD) {}
  func setSpeed(_ rate: Double) { rates.append(rate); currentPlaybackSpeed = rate }
  func setVolume(_ volume: Double, unmute: Bool) { volumes.append(volume); playbackVolume = volume }
  func finishHandoff() {
    isUsingNativePlayback = false
    let callback = pending
    pending = nil
    callback?()
  }
}
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}

_ = NSApplication.shared
let player = PlayerBoundary()
let handler = MenuUnderTest(player)
let item = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: "")
item.representedObject = "16:9"
handler.menuChangeAspect(item)
check(player.aspects == ["16:9"] && player.pending == nil, "Legacy menu behavior stays immediate")
player.aspects = []
player.isUsingNativePlayback = true
handler.menuChangeAspect(item)
check(player.aspects.isEmpty && player.pending != nil, "Native action waits for explicit handoff")
item.representedObject = "4:3"
player.finishHandoff()
check(player.aspects == ["16:9"], "AppKit replays the copied menu value, not a rebuilt menu item")
player.isUsingNativePlayback = true
item.tag = 1
handler.menuCycleTrack(item)
check(player.mpv.commands.isEmpty, "Native track cycling cannot command the idle MPV core")
item.tag = 2
player.finishHandoff()
check(player.mpv.commands == [["audio"]], "AppKit replays the captured track tag after handoff")
player.isUsingNativePlayback = true
handler.menuChangeAspect(item)
player.pending = nil
check(player.aspects.count == 1, "Discarded handoff callbacks do not execute menu side effects")
item.representedObject = 1.1
item.tag = 0
handler.menuChangeSpeed(item)
handler.menuChangeSpeed(item)
check(abs(player.currentPlaybackSpeed - 1.815) < 0.00001, "Repeated menu rates use accepted transport intent")
item.representedObject = 5
handler.menuChangeVolume(item)
handler.menuChangeVolume(item)
check(player.volumes == [35, 40], "Repeated menu volume deltas use accepted transport intent")
check(player.pending == nil, "Supported menu transport actions do not request compatibility")
print("Menu routing checks: \(checks) passed")
