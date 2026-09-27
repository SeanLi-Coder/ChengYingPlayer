import Cocoa

enum LogLevel { case warning }

enum Preference {
  enum Key { case loadIccProfile }
  static var loadICCProfile = true
  static func bool(for key: Key) -> Bool { loadICCProfile }
}

final class MPVBoundary {
  var strings: [String: String] = [:]
  var flags: [String: Bool] = [:]
  var writes = 0
  func setString(_ option: String, _ value: String) {
    writes += 1
    strings[option] = value
  }
  func setFlag(_ option: String, _ value: Bool) {
    writes += 1
    flags[option] = value
  }
}

final class ScreenBoundary {
  var colorSpace: NSColorSpace?
  init(_ colorSpace: NSColorSpace?) { self.colorSpace = colorSpace }
}

final class WindowBoundary { var screen: ScreenBoundary? }
final class MainWindowBoundary { var window: WindowBoundary? = WindowBoundary() }
final class PlayerBoundary {
  let mpv = MPVBoundary()
  let mainWindow = MainWindowBoundary()
}

final class LayerBoundary {
  var colorspace: CGColorSpace? {
    didSet { colorSpaceAssignments += 1 }
  }
  var colorSpaceAssignments = 0
  var wantsExtendedDynamicRangeContent = false
  var acceptsICCProfile = true
  var submittedProfiles: [NSColorSpace] = []
  var autoWasEnabledAtSubmission: [Bool] = []
  unowned let mpv: MPVBoundary
  init(_ mpv: MPVBoundary) { self.mpv = mpv }
  func setRenderICCProfile(_ profile: NSColorSpace) -> Bool {
    submittedProfiles.append(profile)
    autoWasEnabledAtSubmission.append(mpv.flags[MPVOption.GPURendererOptions.iccProfileAuto] == true)
    return acceptsICCProfile
  }
}

class VideoViewBoundary {
  let player = PlayerBoundary()
  lazy var videoLayer = LayerBoundary(player.mpv)
  func logHDR(_ message: String, level: LogLevel? = nil) {}
  func log(_ message: String) {}
}

final class PlaybackInfoBoundary {
  var state = PlayerState.loaded
  var justOpenedFile = false
  var justStartedFile = false
  var disableOSDForFileLoading = true
}

final class PlaybackVideoViewBoundary {
  let colorView = VideoView()
  var refreshes = 0
  var onRefresh: (() -> Void)?
  func refreshEdrMode() {
    refreshes += 1
    onRefresh?()
    colorView.applySDRColorState()
  }
}

final class PlaybackWindowBoundary {
  var loaded = true
  let videoView = PlaybackVideoViewBoundary()
}

enum PlaybackUI { case time }

final class NowPlayingInfoManager {
  static let shared = NowPlayingInfoManager()
  var updates = 0
  func updateInfo() { updates += 1 }
}

class PlaybackBoundary {
  let info = PlaybackInfoBoundary()
  let mainWindow = PlaybackWindowBoundary()
  var loopRestarts: [Bool] = []
  var timeSyncs = 0
  var filterReloads = 0
  func log(_ message: String) {}
  func videoToolsEnforceLoopBounds(playbackRestarted: Bool) { loopRestarts.append(playbackRestarted) }
  func syncUI(_ option: PlaybackUI) { timeSyncs += 1 }
  func reloadSavedIINAfilters() { filterReloads += 1 }
}
