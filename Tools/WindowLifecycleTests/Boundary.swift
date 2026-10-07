import Cocoa

enum Preference {
  enum ScrollAction { case seek, volume, playbackSpeed, none }
  enum SeekOption { case exact }
}

final class PlaybackInfo {
  var state = PlayerState.playing
  var volume = 50.0
  var playSpeed = 1.0
}

final class PlayerCore {
  let mainWindow = PlaybackWindow()
  let info = PlaybackInfo()
  var seeks: [Double] = []
  var volumes: [Double] = []
  var volumeUnmuteRequests: [Bool] = []
  var speeds: [Double] = []
  var pauses = 0
  var resumes = 0
  var deferPauseNotification = false
  func pause() {
    pauses += 1
    if !deferPauseNotification { info.state = .paused }
  }
  func resume() { resumes += 1; info.state = .playing }
  func seek(relativeSecond: Double, option: Preference.SeekOption) { seeks.append(relativeSecond) }
  func setVolume(_ value: Double, unmute: Bool = false) {
    volumes.append(value)
    volumeUnmuteRequests.append(unmute)
    info.volume = value
  }
  func setSpeed(_ value: Double) { speeds.append(value); info.playSpeed = value }
}

final class PlaybackWindow {
  let quickSettingView = PreviewNavigation()
}

final class PreviewNavigation {
  var preparations = 0
  func prepareVideoToolsForUserSeek() { preparations += 1 }
}

final class VideoLayer { var inLiveResize = true }
final class VideoView { let videoLayer = VideoLayer() }
