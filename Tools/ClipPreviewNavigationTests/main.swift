import Foundation

var checks = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  checks += 1
  if !condition() { failures += 1; print("FAIL: \(message)") }
}
func fixture(pending: Bool = false, automaticPending: Bool = false, independent: Bool = false,
             operation: Operation = .clip) -> (PlayerBoundary, PanelUnderTest, WindowUnderTest) {
  let player = PlayerBoundary()
  let panel = PanelUnderTest(player: player)
  panel.selectedOperation = operation
  panel.startField.stringValue = "2"
  panel.endField.stringValue = "80"
  player.mainWindow.quickSettingView.videoToolsViewController = panel
  if automaticPending {
    panel.automaticPreviewPending = true
  } else if pending {
    panel.previewTimer = PendingTimer()
  } else {
    player.videoToolsLoopRange = VideoToolsLoopRange(start: 10, end: 15)
    if !independent { panel.previewSnapshot = true }
  }
  return (player, panel, WindowUnderTest(player: player))
}
func checkPreparation(_ panel: PanelUnderTest, _ context: String) {
  check(panel.stops.count == 1, "\(context): cancels exactly one temporary preview")
  check(panel.stops.first?.0 == true && panel.stops.first?.1 == false,
        "\(context): updates the UI without restoring old position or playback")
  check(panel.previewTimer == nil && panel.previewSnapshot == nil && !panel.automaticPreviewPending,
        "\(context): leaves no pending restart or old snapshot")
}

// A visible panel can await metadata without having a timer or playback snapshot.
// Explicit navigation must cancel that request before changing the playhead.
for action in 0..<7 {
  let (player, panel, window) = fixture(automaticPending: true)
  switch action {
  case 0: window.playSliderChanges(NSSlider())
  case 1: _ = window.handleGuardedPlaybackCommand(["seek", "80", "absolute"])
  case 2: _ = window.handleGuardedPlaybackCommand(["frame-step"])
  case 3: panel.playbackControlClicked(NSSegmentedControl(2))
  case 4: panel.stepFrame(NSSegmentedControl(1))
  case 5: panel.navigateToRangeBoundary(NSSegmentedControl(1))
  default: player.mainWindow.arrowButtonAction(left: false)
  }
  checkPreparation(panel, "Awaiting automatic preview, action=\(action)")
  check(player.events.first == "prepare", "Automatic preview is cancelled before navigation")
  panel.prepareForUserSeek()
  check(panel.stops.count == 1, "Repeated navigation does not recancel a consumed automatic request")
}

for automaticPending in [false, true] {
  let (player, panel, _) = fixture(pending: !automaticPending, automaticPending: automaticPending)
  let timer = panel.previewTimer
  panel.playbackControlClicked(NSSegmentedControl(1))
  check(!panel.automaticPreviewPending && panel.previewTimer == nil,
        "An explicit play/pause choice cancels both pending preview forms")
  check(timer == nil || timer?.invalidated == true, "Play/pause invalidates any scheduled preview timer")
  check(panel.stops.isEmpty && panel.previewSnapshot == nil,
        "Play/pause does not fabricate a preview restore before playback has started")
  check(player.info.state == .paused && player.seeks.isEmpty && panel.updates == 1,
        "Play/pause honors the user's chosen state without an automatic seek")
}

do {
  let (player, panel, _) = fixture()
  let range = player.videoToolsLoopRange
  panel.playbackControlClicked(NSSegmentedControl(1))
  check(panel.previewSnapshot != nil && player.videoToolsLoopRange == range && panel.stops.isEmpty,
        "Pausing an active preview retains its snapshot and selected range")
}

for pending in [false, true] {
  let (player, panel, window) = fixture(pending: pending)
  let timer = panel.previewTimer
  window.playSliderChanges(NSSlider())
  checkPreparation(panel, "Timeline, pending=\(pending)")
  check(player.seeks == [80], "Timeline can seek outside the temporary preview")
  check(player.events == ["prepare", "seek"], "Timeline prepares before seeking, without pause/resume")
  check(timer == nil || timer?.invalidated == true, "Timeline invalidates a pending preview")
  window.playSliderChanges(NSSlider())
  check(panel.stops.count == 1, "Subsequent timeline drag packets do not restore the old preview again")
}

for tokens in [["seek", "80", "absolute"], ["seek", "20"], ["seek", "80", "absolute-percent"],
               ["seek", "20", "relative-percent"], ["frame-step"], ["frame-back-step"]] {
  for pending in [false, true] {
    let (player, panel, window) = fixture(pending: pending)
    check(!window.handleGuardedPlaybackCommand(tokens), "Temporary navigation returns to the normal mpv binding")
    checkPreparation(panel, "Keyboard \(tokens), pending=\(pending)")
    check(player.events == ["prepare"], "The normal key binding is not executed twice")
  }
}

for pending in [false, true] {
  let (player, panel, window) = fixture(pending: pending)
  for tokens in [["seek", "nan"], ["seek", "1", "unknown"], ["seek", "10;quit"], ["quit"]] {
    check(!window.handleGuardedPlaybackCommand(tokens), "Unknown or malformed commands retain their original route")
    check(panel.stops.isEmpty, "Malformed commands cannot stop a temporary preview")
  }
  player.info.videoDuration = nil
  check(!window.handleGuardedPlaybackCommand(["seek", "-5", "absolute"]),
        "A negative absolute seek without duration defers to mpv")
  check(panel.stops.isEmpty, "An unresolvable absolute target does not cancel preview")
}

for mode in [Operation.clip, .frames] {
  for pending in [false, true] {
    for segment in [0, 2] {
      let (player, panel, _) = fixture(pending: pending, operation: mode)
      panel.playbackControlClicked(NSSegmentedControl(segment))
      checkPreparation(panel, "Panel skip")
      check(player.seeks == [segment == 0 ? 7 : 17], "Panel skip can leave either edge of a temporary preview")
      check(player.events == ["prepare", "seek"], "Panel skip retains current playback state")
    }
    for segment in [0, 1] {
      let (player, panel, _) = fixture(pending: pending, operation: mode)
      panel.stepFrame(NSSegmentedControl(segment))
      checkPreparation(panel, "Panel frame step")
      check(player.events == ["prepare", "pause", "frame"], "Frame step prepares before pausing and stepping")
      check(player.frames == [segment == 0], "Frame direction is preserved")
      let (boundaryPlayer, boundaryPanel, _) = fixture(pending: pending, operation: mode)
      boundaryPanel.navigateToRangeBoundary(NSSegmentedControl(segment))
      checkPreparation(boundaryPanel, "Panel boundary")
      check(boundaryPlayer.seeks == [segment == 0 ? 2 : 80], "Boundary navigation is not clamped to old preview")
      check(boundaryPlayer.events == ["prepare", "pause", "seek"], "Boundary navigation retains its pause behavior")
    }
  }
}

for pending in [false, true] {
  for left in [false, true] {
    let (player, panel, _) = fixture(pending: pending)
    player.mainWindow.arrowButtonAction(left: left)
    checkPreparation(panel, "Transport arrow")
    check(player.seeks == [left ? 2 : 22], "Transport arrows can select points outside preview")
    check(player.events == ["prepare", "seek"], "Transport arrows prepare before seeking")
  }
}

for tokens in [["seek", "80", "absolute"], ["seek", "20"], ["seek", "80", "absolute-percent"],
               ["seek", "20", "relative-percent"], ["frame-step"], ["frame-back-step"]] {
  let (player, panel, window) = fixture(independent: true)
  let oldRange = player.videoToolsLoopRange
  check(window.handleGuardedPlaybackCommand(tokens), "Independent A/B bindings still use guarded navigation")
  check(panel.stops.isEmpty && player.videoToolsLoopRange == oldRange,
        "Independent A/B loop is never cleared by temporary-preview preparation")
  check(player.seeks.allSatisfy { oldRange!.contains($0) }, "Independent A/B seeks remain inside the selected loop")
}

for mode in [Operation.rotate, .convert] {
  let (player, panel, window) = fixture(operation: mode)
  let original = player.videoToolsLoopRange
  window.playSliderChanges(NSSlider())
  check(panel.stops.isEmpty && panel.previewSnapshot != nil,
        "Non-range previews are not cancelled by timeline navigation")
  check(player.videoToolsLoopRange == original, "Navigation does not change unrelated preview state")
}

for pending in [false, true] {
  let (player, panel, window) = fixture(pending: pending)
  _ = window.handleGuardedPlaybackCommand(["add", "speed", "0.1"])
  check(panel.stops.isEmpty, "Speed changes retain the temporary range")
  player.mainWindow.arrowBtnFunction = .speed
  player.mainWindow.arrowButtonAction(left: false)
  check(panel.stops.isEmpty && player.speeds.last == 2, "Speed arrows do not cancel previews")
  player.mainWindow.arrowBtnFunction = .playlist
  player.mainWindow.arrowButtonAction(left: true)
  check(panel.stops.isEmpty && player.playlist == [false], "Playlist arrows retain their independent lifecycle")
}

do {
  let (player, panel, window) = fixture(pending: true)
  player.info.state = .idle
  window.playSliderChanges(NSSlider())
  panel.playbackControlClicked(NSSegmentedControl(0))
  panel.stepFrame(NSSegmentedControl(1))
  panel.navigateToRangeBoundary(NSSegmentedControl(1))
  check(panel.stops.isEmpty && player.events.isEmpty, "Inactive navigation does not touch the player")
  player.info.state = .playing
  panel.endField.stringValue = "invalid"
  panel.navigateToRangeBoundary(NSSegmentedControl(1))
  check(panel.stops.isEmpty && player.events.isEmpty, "Invalid boundary input does not cancel previews")
}
do {
  let player = PlayerBoundary()
  let window = WindowUnderTest(player: player)
  window.playSliderChanges(NSSlider())
  check(player.mainWindow.quickSettingView.videoToolsViewController == nil,
        "Ordinary playback navigation does not instantiate a tools panel")
  check(player.seeks == [80], "Navigation without a tools panel still works")
}

print("Clip preview navigation checks: \(checks), failures: \(failures)")
exit(failures == 0 ? 0 : 1)
