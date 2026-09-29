import Foundation

// Only UI/player boundaries are simulated. Navigation bodies and command parsing
// are extracted unchanged from production; this is not a decoder/render test.
enum Preference { enum SeekOption { case exact, relative } }
enum Operation { case clip, frames, rotate, convert }
enum ArrowAction { case speed, playlist, seek }
enum AppData { static let availableSpeedValues = [1.0, 2.0, 4.0] }
struct VideoTime { let second: Double }
final class NSSlider { var doubleValue = 80.0; var maxValue = 100.0 }
final class NSSegmentedControl {
  var selectedSegment: Int
  init(_ segment: Int) { selectedSegment = segment }
}
final class NSTextField { var stringValue = "0" }
final class PendingTimer {
  var invalidated = false
  func invalidate() { invalidated = true }
}
final class PlaybackInfo {
  var state = PlayerState.playing
  var videoDuration: VideoTime? = VideoTime(second: 100)
}
final class MPVBoundary {
  var speed = 1.0
  func getDouble(_ name: String) -> Double { speed }
}
final class PlayerBoundary {
  let info = PlaybackInfo()
  let mpv = MPVBoundary()
  lazy var mainWindow = MainWindowUnderTest(player: self)
  var videoToolsLoopRange: VideoToolsLoopRange?
  var videoToolsCurrentTime: Double? = 12
  var events: [String] = []
  var seeks: [Double] = []
  var frames: [Bool] = []
  var playlist: [Bool] = []
  var speeds: [Double] = []
  func seek(absoluteSecond: Double) {
    let target = videoToolsLoopRange?.clamped(absoluteSecond) ?? absoluteSecond
    events.append("seek")
    seeks.append(target)
    videoToolsCurrentTime = target
  }
  func seek(relativeSecond: Double, option: Preference.SeekOption) {
    seek(absoluteSecond: (videoToolsCurrentTime ?? 0) + relativeSecond)
  }
  func seek(percent: Double, forceExact: Bool) {
    seek(absoluteSecond: (info.videoDuration?.second ?? 0) * percent / 100)
  }
  func videoToolsSeek(to seconds: Double, pausePlayback: Bool) {
    if pausePlayback { pause() }
    seek(absoluteSecond: seconds)
  }
  func pause() { events.append("pause"); info.state = .paused }
  func resume() { events.append("resume"); info.state = .playing }
  func togglePause() { info.state == .paused ? resume() : pause() }
  func frameStep(backwards: Bool) { events.append("frame"); frames.append(backwards) }
  func setSpeed(_ speed: Double) { events.append("speed"); mpv.speed = speed; speeds.append(speed) }
  func navigateInPlaylist(nextMedia: Bool) { events.append("playlist"); playlist.append(nextMedia) }
}
final class PanelUnderTest {
  let player: PlayerBoundary?
  var selectedOperation = Operation.clip
  var previewSnapshot: Bool?
  var previewTimer: PendingTimer?
  var priorLoop: VideoToolsLoopRange?
  var stops: [(Bool, Bool)] = []
  var updates = 0
  let startField = NSTextField()
  let endField = NSTextField()
  init(player: PlayerBoundary) { self.player = player }
  func stopPreview(updateButton: Bool, restorePlaybackState: Bool) {
    player?.events.append("prepare")
    stops.append((updateButton, restorePlaybackState))
    previewTimer?.invalidate()
    previewTimer = nil
    if previewSnapshot != nil { player?.videoToolsLoopRange = priorLoop }
    previewSnapshot = nil
  }
  func updatePlaybackControls() { updates += 1 }
  func parseTimestamp(_ value: String) -> Double? { Double(value) }
}
final class SettingsUnderTest { var videoToolsViewController: PanelUnderTest? }
final class WindowUnderTest {
  let player: PlayerBoundary
  var followGlobalSeekTypeWhenAdjustSlider = false
  init(player: PlayerBoundary) { self.player = player }
}
final class MainWindowUnderTest {
  let player: PlayerBoundary
  let quickSettingView = SettingsUnderTest()
  var arrowBtnFunction = ArrowAction.seek
  var isFastforwarding = false
  var speedValueIndex = 1
  init(player: PlayerBoundary) { self.player = player }
}
