import Cocoa

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
  checks += 1
  print("PASS: \(message)")
}

let gpu = MPVOption.GPURendererOptions.self
let screenshot = MPVOption.Screenshot.self
let displayP3 = NSColorSpace.displayP3
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func fixture(profile: NSColorSpace? = displayP3, useICC: Bool = true,
             acceptsICC: Bool = true) -> VideoView {
  Preference.loadICCProfile = useICC
  let view = VideoView()
  view.player.mainWindow.window?.screen = ScreenBoundary(profile)
  view.videoLayer.acceptsICCProfile = acceptsICC
  return view
}

func seedHDRState(_ view: VideoView) {
  view.videoLayer.wantsExtendedDynamicRangeContent = true
  view.player.mpv.strings = [gpu.targetTrc: "pq", gpu.targetPrim: "bt.2020",
                            gpu.targetPeak: "1600", gpu.toneMapping: "clip",
                            gpu.toneMappingParam: "0.5"]
  view.player.mpv.flags = [gpu.iccProfileAuto: true, screenshot.screenshotTagColorspace: true]
}

func verifySDR(_ view: VideoView, usesICC: Bool, context: String) {
  let mpv = view.player.mpv
  check(!view.videoLayer.wantsExtendedDynamicRangeContent, "\(context): EDR is disabled")
  check(mpv.strings[gpu.targetTrc] == (usesICC ? "auto" : "srgb"), "\(context): output transfer matches the SDR path")
  check(mpv.strings[gpu.targetPrim] == (usesICC ? "auto" : "bt.709"), "\(context): output primaries match the SDR path")
  check(mpv.strings[gpu.targetPeak] == "auto", "\(context): stale HDR target peak is cleared")
  check(mpv.strings[gpu.toneMapping] == "auto", "\(context): HDR-to-SDR tone mapping is restored")
  check(mpv.strings[gpu.toneMappingParam] == "default", "\(context): stale tone-mapping parameter is cleared")
  check(mpv.flags[screenshot.screenshotTagColorspace] == false, "\(context): HDR screenshot tagging is disabled")
  check(mpv.flags[gpu.iccProfileAuto] == usesICC, "\(context): automatic ICC matches profile acceptance")
  check(view.videoLayer.colorspace == (usesICC ? displayP3.cgColorSpace : sRGB),
        "\(context): layer describes the RGB values actually produced")
}

check(VideoView.SRGB == sRGB, "The fallback is a named sRGB space, not uncalibrated device RGB")

let managed = fixture()
if #available(macOS 11.0, *) {
  managed.videoLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
} else {
  managed.videoLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2020)
}
seedHDRState(managed)
managed.applySDRColorState()
verifySDR(managed, usesICC: true, context: "HDR to managed SDR")
check(managed.videoLayer.submittedProfiles.count == 1 && managed.videoLayer.autoWasEnabledAtSubmission == [true],
      "ICC auto mode is enabled before the display profile is submitted")
let managedAssignments = managed.videoLayer.colorSpaceAssignments
seedHDRState(managed)
managed.applySDRColorState()
verifySDR(managed, usesICC: true, context: "Reused layer with the same display profile")
check(managed.videoLayer.colorSpaceAssignments == managedAssignments,
      "Resetting mpv state does not require reassigning an unchanged layer profile")

let disabled = fixture(useICC: false)
disabled.videoLayer.colorspace = displayP3.cgColorSpace
seedHDRState(disabled)
disabled.applySDRColorState()
verifySDR(disabled, usesICC: false, context: "ICC explicitly disabled on a wide-gamut display")
check(disabled.videoLayer.submittedProfiles.isEmpty, "Disabling ICC never submits a display profile")
check(!Preference.loadICCProfile, "Applying SDR does not rewrite the disabled ICC preference")
let unmanagedAssignments = disabled.videoLayer.colorSpaceAssignments
seedHDRState(disabled)
disabled.applySDRColorState()
verifySDR(disabled, usesICC: false, context: "Reused unmanaged sRGB layer")
check(disabled.videoLayer.colorSpaceAssignments == unmanagedAssignments,
      "An unchanged sRGB layer still receives a complete SDR state reset")

let failed = fixture(acceptsICC: false)
failed.videoLayer.colorspace = displayP3.cgColorSpace
seedHDRState(failed)
failed.applySDRColorState()
verifySDR(failed, usesICC: false, context: "ICC submission failed")
check(failed.videoLayer.autoWasEnabledAtSubmission == [true], "A rejected ICC submission still follows the required option ordering")
check(Preference.loadICCProfile, "ICC failure does not overwrite the enabled ICC preference")
failed.videoLayer.acceptsICCProfile = true
failed.applySDRColorState()
verifySDR(failed, usesICC: true, context: "ICC submission recovered")

let missingProfile = fixture(profile: nil)
seedHDRState(missingProfile)
missingProfile.applySDRColorState()
verifySDR(missingProfile, usesICC: false, context: "Display profile unavailable")
check(missingProfile.videoLayer.submittedProfiles.isEmpty, "No profile is submitted when the display has none")

let missingScreen = fixture()
missingScreen.player.mainWindow.window?.screen = nil
seedHDRState(missingScreen)
missingScreen.applySDRColorState()
verifySDR(missingScreen, usesICC: false, context: "Display unavailable during transition")

let missingWindow = fixture()
missingWindow.player.mainWindow.window = nil
seedHDRState(missingWindow)
missingWindow.applySDRColorState()
verifySDR(missingWindow, usesICC: false, context: "Window unavailable during transition")

func playbackFixture() -> PlayerCore {
  Preference.loadICCProfile = true
  let player = PlayerCore()
  let view = player.mainWindow.videoView.colorView
  view.player.mainWindow.window?.screen = ScreenBoundary(displayP3)
  view.videoLayer.colorspace = displayP3.cgColorSpace
  seedHDRState(view)
  view.player.mpv.flags[gpu.iccProfileAuto] = false
  return player
}

for (state, opened, started, context) in [
  (PlayerState.loaded, true, false, "Manually opened file"),
  (.playing, false, true, "Next playlist file"),
  (.paused, true, true, "New file paused on its first frame"),
] {
  let player = playbackFixture()
  player.info.state = state
  player.info.justOpenedFile = opened
  player.info.justStartedFile = started
  var flagsAtRefresh = (false, false)
  player.mainWindow.videoView.onRefresh = {
    flagsAtRefresh = (player.info.justOpenedFile, player.info.justStartedFile)
  }
  let nowPlayingUpdates = NowPlayingInfoManager.shared.updates
  player.playbackRestarted()
  check(player.mainWindow.videoView.refreshes == 1, "\(context): first ready frame refreshes color state")
  check(flagsAtRefresh.0 == opened && flagsAtRefresh.1 == started,
        "\(context): color refresh happens before file-start flags are cleared")
  check(!player.info.justOpenedFile && !player.info.justStartedFile,
        "\(context): existing file-start flags are still cleared")
  check(player.loopRestarts == [true] && player.timeSyncs == 1 && player.filterReloads == 1,
        "\(context): existing loop, time and filter handlers still run")
  check(NowPlayingInfoManager.shared.updates == nowPlayingUpdates + 1,
        "\(context): now-playing information is still updated")
  check(player.info.state == state, "\(context): the playback and pause state is preserved")
  verifySDR(player.mainWindow.videoView.colorView, usesICC: true, context: context)

  let mpvWrites = player.mainWindow.videoView.colorView.player.mpv.writes
  player.playbackRestarted()
  player.playbackRestarted()
  check(player.mainWindow.videoView.refreshes == 1 &&
        player.mainWindow.videoView.colorView.player.mpv.writes == mpvWrites,
        "\(context): ordinary seeks and loop restarts do not repeat color setup")
  check(player.loopRestarts == [true, true, true] && player.timeSyncs == 3 && player.filterReloads == 3,
        "\(context): repeated restarts still execute the existing playback handlers")

  // No color-space notification or tag change occurs for the next file.
  player.info.justStartedFile = true
  player.mainWindow.videoView.colorView.player.mpv.flags[gpu.iccProfileAuto] = false
  player.playbackRestarted()
  check(player.mainWindow.videoView.refreshes == 2 &&
        player.mainWindow.videoView.colorView.player.mpv.flags[gpu.iccProfileAuto] == true,
        "\(context): the next file restores ICC even with identical color tags and display")
  player.mainWindow.videoView.onRefresh = nil
}

for state in [PlayerState.stopping, .idle, .shuttingDown, .shutDown] {
  let player = playbackFixture()
  player.info.state = state
  player.info.justStartedFile = true
  player.playbackRestarted()
  check(player.mainWindow.videoView.refreshes == 0 &&
        player.mainWindow.videoView.colorView.player.mpv.writes == 0,
        "Inactive state \(state): color refresh does not reach the view or mpv")
}

let unloadedPlayerWindow = playbackFixture()
unloadedPlayerWindow.mainWindow.loaded = false
unloadedPlayerWindow.info.justStartedFile = true
unloadedPlayerWindow.playbackRestarted()
check(unloadedPlayerWindow.mainWindow.videoView.refreshes == 0 &&
      unloadedPlayerWindow.mainWindow.videoView.colorView.player.mpv.writes == 0,
      "An unloaded player window prevents color setup from reaching mpv")

print("HDR color-state checks passed: \(checks)")
print("Coverage: compiled production SDR and playback-restart methods with real color spaces, player-state guards and recording boundaries; no GPU rendering or HDR display acceptance.")
