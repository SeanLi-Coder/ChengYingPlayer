import Cocoa

setbuf(stdout, nil)
_ = NSApplication.shared
defer { ChromeDefaults.value.removePersistentDomain(forName: ChromeDefaults.suite) }

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}

func withFixture(_ test: (MainWindowUnderTest) -> Void) {
  ChromeAnimations.reset()
  ChromeInput.pressedMouseButtons = 0
  ChromeInput.cursorHides = []
  Preference.autoHide = true
  Preference.timeout = 2.5
  Preference.disableAnimations = false
  AccessibilityPreferences.motionReductionEnabled = false
  let controller = MainWindowUnderTest()
  defer {
    controller.destroyTimer()
    ChromeAnimations.reset()
    controller.window?.testResponder = nil
    controller.window?.testSheet = nil
    controller.window?.close()
  }
  test(controller)
}

func mouseMove(_ controller: MainWindowUnderTest, point: NSPoint) {
  controller.window!.testPointer = point
  let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                 windowNumber: controller.window!.windowNumber, context: nil,
                                 eventNumber: 1, clickCount: 0, pressure: 0)!
  controller.mouseMoved(with: event)
}

withFixture { controller in
  check(controller.hideUI(), "The first idle hide starts")
  let hide1 = ChromeAnimations.pending.count - 1
  check(controller.animationState == .willHide, "The first hide is pending")
  controller.showUI()
  let show2 = ChromeAnimations.pending.count - 1
  check(controller.hideUI(), "A later idle hide starts after an interrupted show")
  let hide3 = ChromeAnimations.pending.count - 1
  ChromeAnimations.complete(hide1)
  check(controller.animationState == .willHide, "The stale first hide cannot complete the third hide")
  check(!controller.fragSliderView.isHidden, "The stale first hide cannot hide the new timeline early")
  ChromeAnimations.complete(show2)
  check(controller.animationState == .willHide, "The stale show cannot restore a newer hide state")
  ChromeAnimations.complete(hide3)
  check(controller.animationState == .hidden && controller.fragSliderView.isHidden,
        "Only the current hide completion hides the timeline")
  check(controller.standardWindowButtons.allSatisfy { !$0.isHidden && $0.alphaValue > 0 && $0.alphaValue < 0.01 },
        "Window buttons retain the production nearly-transparent workaround")
  controller.showUI()
  ChromeAnimations.drain()
  check(controller.animationState == .shown && !controller.fragSliderView.isHidden && controller.fragSliderView.alphaValue == 1,
        "Mouse activity restores the timeline after a completed hide")
  let stableCount = ChromeAnimations.pending.count
  let stableRefreshes = controller.player.refreshes
  for _ in 0..<20 { controller.showUI() }
  check(ChromeAnimations.pending.count == stableCount && controller.player.refreshes == stableRefreshes,
        "An already-shown UI does not repeatedly enqueue animations or playback refreshes")
  controller.showUI(force: true)
  check(ChromeAnimations.pending.count == stableCount + 1, "An explicit forced refresh still works")
}

withFixture { controller in
  controller.hideUI()
  let completion = ChromeAnimations.pending.count - 1
  controller.createTimer()
  let oldTimer = controller.hideControlTimer!
  let generation = controller.chromeAnimationGeneration
  controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
  check(controller.chromeAnimationGeneration > generation, "Closing invalidates the current chrome generation")
  check(controller.hideControlTimer == nil && !oldTimer.isValid, "Closing invalidates the pending auto-hide timer")
  check(controller.player.stops == 1 && controller.player.events.closed == 1, "The actual close path stops playback and emits its event")
  let resets = controller.window!.cursorResets
  ChromeAnimations.complete(completion)
  check(!controller.fragSliderView.isHidden && controller.animationState == .hidden,
        "A completed old hide cannot alter a closed window")
  check(controller.window!.cursorResets == resets, "Stale chrome completion does not touch the closed window's cursor rectangles")
}

withFixture { controller in
  controller.createTimer()
  let initial = controller.hideControlTimer!
  controller.beginControlInteraction()
  controller.beginControlInteraction()
  check(!initial.isValid && controller.hideControlTimer == nil && controller.controlInteractionDepth == 2,
        "Nested press and drag tracking suspends the timer")
  controller.hideUIAndCursor()
  check(ChromeInput.cursorHides.isEmpty && controller.animationState == .shown,
        "Active control tracking protects both controls and cursor")
  controller.endControlInteraction()
  check(controller.controlInteractionDepth == 1 && controller.hideControlTimer == nil,
        "Ending the inner interaction cannot restart auto-hide")
  controller.endControlInteraction()
  check(controller.controlInteractionDepth == 0 && controller.hideControlTimer?.isValid == true,
        "Ending the last interaction restarts auto-hide")
  controller.endControlInteraction()
  check(controller.controlInteractionDepth == 0, "An unmatched release cannot make interaction depth negative")
  controller.destroyTimer()
  controller.window!.testVisible = false
  controller.beginControlInteraction()
  controller.endControlInteraction()
  check(controller.hideControlTimer == nil, "Releasing after the window closes cannot restart its timer")
}

for initialState in [MainWindowUnderTest.UIAnimationState.shown, .hidden, .willHide, .willShow] {
  withFixture { controller in
    switch initialState {
    case .shown: break
    case .hidden:
      controller.hideUI()
      ChromeAnimations.drain()
    case .willHide:
      controller.hideUI()
    case .willShow:
      controller.hideUI()
      ChromeAnimations.drain()
      controller.showUI()
    }
    check(controller.animationState == initialState, "Establish the real pre-transition chrome state: \(initialState)")
    let oldPending = ChromeAnimations.pending.indices.filter { ChromeAnimations.pending[$0] != nil }
    let freshTitlebar = NSView(frame: NSRect(x: 0, y: 440, width: 650, height: 35))
    let additionalInfo = NSView(frame: NSRect(x: 20, y: 350, width: 100, height: 50))
    for view in [freshTitlebar, additionalInfo] {
      view.isHidden = true
      view.alphaValue = 0
      controller.window!.contentView!.addSubview(view)
      controller.fadeableViews.append(view)
    }
    let generation = controller.chromeAnimationGeneration
    let refreshes = controller.player.refreshes
    controller.refreshChromeAfterWindowTransition()
    let latest = ChromeAnimations.pending.count - 1
    check(controller.chromeAnimationGeneration > generation && controller.player.refreshes == refreshes + 1,
          "A window transition forces a new chrome generation from \(initialState)")
    check([freshTitlebar, additionalInfo].allSatisfy { !$0.isHidden && $0.alphaValue == 1 },
          "Dynamic titlebar and additional-info membership becomes visible from \(initialState)")
    check(controller.animationState == .willShow && controller.hideControlTimer?.isValid == true,
          "A refreshed active window schedules its new show and idle timer from \(initialState)")
    oldPending.forEach { ChromeAnimations.complete($0) }
    check(controller.animationState == .willShow && !controller.fragSliderView.isHidden && !freshTitlebar.isHidden,
          "Older fade completions cannot override the new window-transition refresh from \(initialState)")
    ChromeAnimations.complete(latest)
    check(controller.animationState == .shown && additionalInfo.alphaValue == 1,
          "Only the newest window-transition completion finishes the refreshed UI from \(initialState)")
  }
}

for state in [PlayerState.stopping, .idle, .shuttingDown, .shutDown] {
  for disabled in [false, true] {
    withFixture { controller in
      controller.player.info.state = state
      controller.player.disableUI = disabled
      let generation = controller.chromeAnimationGeneration
      controller.refreshChromeAfterWindowTransition()
      check(controller.player.refreshes == 0 && ChromeAnimations.pending.isEmpty && controller.hideControlTimer == nil
              && controller.chromeAnimationGeneration == generation,
            "A fullscreen completion cannot touch playback or schedule chrome after \(state), disabled UI: \(disabled)")
    }
  }
}

withFixture { controller in
  controller.player.disableUI = true
  Preference.autoHide = false
  controller.animationState = .hidden
  let additionalInfo = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
  controller.window!.contentView!.addSubview(additionalInfo)
  controller.fadeableViews.append(additionalInfo)
  controller.refreshChromeAfterWindowTransition()
  check(controller.animationState == .willHide && additionalInfo.alphaValue == 0,
        "Active disabled UI forcibly hides newly added fullscreen chrome even when auto-hide is disabled")
  ChromeAnimations.drain()
  check(controller.animationState == .hidden && additionalInfo.isHidden && controller.hideControlTimer == nil,
        "Disabled-UI fullscreen refresh remains hidden without scheduling a new timer")
}

withFixture { controller in
  controller.oscPosition = .floating
  let toolbarPoint = NSPoint(x: 80, y: 75)
  controller.window!.testPointer = toolbarPoint
  check(controller.pointerIsOverControls && !controller.hideUI(),
        "Legacy toolbar hover protects the controls through its real native view")
  controller.createTimer()
  mouseMove(controller, point: toolbarPoint)
  check(controller.hideControlTimer == nil, "Mouse movement across the legacy toolbar suspends auto-hide")
  controller.fragToolbarView.isHidden = true
  check(!controller.pointerIsOverControls, "A hidden legacy toolbar cannot retain an invisible hit target")
}

withFixture { controller in
  let guards: [(String, () -> Void, () -> Void)] = [
    ("interactive editing mode", { controller.isInInteractiveMode = true }, { controller.isInInteractiveMode = false }),
    ("floating-control dragging", { controller.controlBarFloating.isDragging = true }, { controller.controlBarFloating.isDragging = false }),
    ("sidebar resizing", { controller.isResizingSidebar = true }, { controller.isResizingSidebar = false }),
    ("pressed mouse buttons", { ChromeInput.pressedMouseButtons = 1 }, { ChromeInput.pressedMouseButtons = 0 }),
    ("an attached sheet", { controller.window!.testSheet = NSWindow() }, { controller.window!.testSheet = nil }),
    ("sidebar opening", { controller.sidebarAnimationState = .willShow }, { controller.sidebarAnimationState = .hidden }),
    ("sidebar closing", { controller.sidebarAnimationState = .willHide }, { controller.sidebarAnimationState = .hidden })
  ]
  for (name, enable, disable) in guards {
    enable()
    check(!controller.hideUI(), "Automatic hiding is blocked during \(name)")
    check(controller.animationState == .shown && controller.hideControlTimer?.isValid == true,
          "Blocked \(name) reschedules a later check without starting an animation")
    disable()
  }
  controller.window!.testPointer = NSPoint(x: 300, y: 10)
  check(!controller.hideUI(), "A pointer over the visible timeline protects controls")
  controller.fragSliderView.isHidden = true
  check(!controller.pointerIsOverControls, "A hidden timeline cannot indefinitely suppress auto-hide")
  controller.fragSliderView.isHidden = false
  controller.window!.testPointer = NSPoint(x: 350, y: 250)
  controller.pipStatus = .inPIP
  check(!controller.hideUI(force: true), "Even forced hiding preserves picture-in-picture controls")
  controller.pipStatus = .notInPIP
  Preference.autoHide = false
  check(!controller.hideUI(), "Disabling auto-hide blocks the idle path")
  check(controller.hideUI(force: true), "An explicit forced hide bypasses the idle preference")
}

for reduceMotion in [false, true] {
  withFixture { controller in
    AccessibilityPreferences.motionReductionEnabled = reduceMotion
    controller.showPlaylistSidebar()
    ChromeAnimations.drain()
    check(controller.sideBarStatus == .playlist && controller.sidebarAnimationState == .shown && controller.isSidebarVisible,
          "The real sidebar-open methods expose the playlist (reduce motion: \(reduceMotion))")
    check(controller.playlistView.downShift == 0 && controller.sideBarRightConstraint.constant == 8,
          "The edge sidebar uses its compact top offset and inset")
    check(controller.playlistView.useCompactTabHeight,
          "The edge playlist enables compact tabs so complete rows fit in small windows")
    let children = controller.sideBarView.subviews
    let content = controller.playlistView.view
    let editor = NSTextView(frame: NSRect(x: 5, y: 5, width: 150, height: 20))
    content.addSubview(editor)
    controller.window!.testResponder = editor
    check(!controller.hideUI(), "An active text editor inside the sidebar blocks idle hiding")
    controller.window!.testResponder = nil
    editor.removeFromSuperview()
    let field = ChromeTextField(frame: NSRect(x: 5, y: 5, width: 150, height: 20))
    content.addSubview(field)
    let fieldEditor = NSTextView()
    fieldEditor.isFieldEditor = true
    fieldEditor.delegate = field
    controller.window!.testResponder = fieldEditor
    check(!controller.hideUI(), "A window field editor delegated to a sidebar search field blocks idle hiding")
    controller.window!.testResponder = nil
    fieldEditor.delegate = nil
    field.removeFromSuperview()
    controller.hideUIAndCursor()
    ChromeAnimations.drain()
    check(controller.sideBarStatus == .playlist && controller.sideBarView.subviews == children,
          "Idle hiding retains the selected panel and exact child-view instances")
    check(controller.sidebarAutoHidden && !controller.isSidebarVisible && controller.sideBarView.isHidden,
          "Idle hiding visually conceals the sidebar without closing it")
    check(ChromeInput.cursorHides == [true], "A successful idle hide conceals the cursor")
    mouseMove(controller, point: NSPoint(x: 350, y: 250))
    ChromeAnimations.drain()
    check(controller.isSidebarVisible && !controller.sidebarAutoHidden && controller.sideBarView.subviews == children,
          "Real mouse-move handling restores the same playlist panel and contents")
    check(controller.hideControlTimer?.isValid == true && controller.seekPreviewRefreshes == 1,
          "Moving over video refreshes the preview and restarts the idle timer")
    mouseMove(controller, point: NSPoint(x: 300, y: 10))
    check(controller.hideControlTimer == nil, "Moving over the timeline suspends the idle timer")
    var closes = 0
    controller.hideSideBar { closes += 1 }
    ChromeAnimations.drain()
    check(controller.sideBarStatus == .hidden && controller.sideBarView.subviews.isEmpty && !controller.isSidebarVisible,
          "Only explicit closing clears the sidebar status and child content")
    check(closes == 1 && controller.sidebarAnimationState == .hidden && controller.sideBarView.alphaValue == 1,
          "Explicit close invokes its callback exactly once and restores reusable opacity")
  }
}

withFixture { controller in
  controller.showPlaylistSidebar()
  ChromeAnimations.drain()
  check(controller.playlistView.useCompactTabHeight, "Establish compact playlist tabs in edge-control mode")
  controller.hideSideBar(animate: false)
  ChromeAnimations.drain()
  controller.oscPosition = .floating
  controller.titleBarHeightConstraint.constant = 42
  controller.titleBarView.frame.size.height = 17
  controller.showPlaylistSidebar()
  ChromeAnimations.drain()
  check(!controller.playlistView.useCompactTabHeight, "Reusing the playlist in legacy mode restores its full tab height")
  check(controller.playlistView.downShift == 42 && controller.sideBarRightConstraint.constant == 0,
        "Legacy sidebar offset uses the current titlebar constraint instead of a stale frame height")
}

withFixture { controller in
  controller.showPlaylistSidebar()
  let opening = ChromeAnimations.pending.count - 1
  let pendingCount = ChromeAnimations.pending.count
  controller.showSettingsSidebar(tab: .audio)
  controller.showPlaylistSidebar(tab: .chapters)
  check(ChromeAnimations.pending.count == pendingCount && controller.sideBarStatus == .playlist,
        "Ordinary repeated sidebar clicks cannot enqueue competing transitions while opening")
  controller.showSettingsSidebar(tab: .audio, force: true)
  let closeForSettings = ChromeAnimations.pending.count - 1
  ChromeAnimations.complete(closeForSettings)
  let settingsOpening = ChromeAnimations.pending.count - 1
  check(controller.sideBarStatus == .settings && controller.sideBarView.subviews.first === controller.quickSettingView.view,
        "Forced playlist-to-settings switching replaces the panel once the current close completes")
  check(controller.quickSettingView.currentTab == .audio, "The requested settings tab survives switching")
  ChromeAnimations.complete(opening)
  check(controller.sidebarAnimationState == .willShow, "The old playlist-open completion cannot finish settings opening")
  ChromeAnimations.complete(settingsOpening)
  check(controller.sidebarAnimationState == .shown, "The current settings completion marks its own panel shown")
  controller.showPlaylistSidebar(tab: .chapters, force: true)
  let staleClose = ChromeAnimations.pending.count - 1
  controller.showSideBar(viewController: controller.quickSettingView, type: .settings)
  let latestSettingsOpening = ChromeAnimations.pending.count - 1
  ChromeAnimations.complete(staleClose)
  check(controller.sideBarStatus == .settings && controller.sideBarView.subviews.first === controller.quickSettingView.view,
        "An old close cannot erase a newly opened settings panel or invoke its playlist callback")
  ChromeAnimations.complete(latestSettingsOpening)
  check(controller.sidebarAnimationState == .shown, "The latest settings generation remains authoritative")
  ChromeAnimations.drain()
}

withFixture { controller in
  controller.showPlaylistSidebar()
  ChromeAnimations.drain()
  controller.showSettingsSidebar(force: true)
  let staleSettingsClose = ChromeAnimations.pending.count - 1
  controller.showPlaylistSidebar(force: true)
  let latestPlaylistClose = ChromeAnimations.pending.count - 1
  ChromeAnimations.complete(latestPlaylistClose)
  ChromeAnimations.complete(staleSettingsClose)
  ChromeAnimations.drain()
  check(controller.sideBarStatus == .hidden && controller.sideBarView.subviews.isEmpty,
        "An abandoned settings-switch callback cannot reopen content after a newer explicit close")
}

withFixture { controller in
  controller.showPlaylistSidebar()
  ChromeAnimations.drain()
  controller.hideUI()
  let staleAutoHide = ChromeAnimations.pending.count - 1
  controller.hideSideBar(animate: false)
  let explicitClose = ChromeAnimations.pending.count - 1
  ChromeAnimations.complete(explicitClose)
  controller.showSettingsSidebar()
  ChromeAnimations.drain()
  check(ChromeAnimations.pending[staleAutoHide] == nil, "All pending auto-hide completions have been exercised")
  check(controller.sideBarStatus == .settings && controller.isSidebarVisible && !controller.fragSliderView.isHidden,
        "An old auto-hide cannot conceal new settings after explicit close and reopen")
}

withFixture { controller in
  controller.showPlaylistSidebar()
  let pendingSidebar = ChromeAnimations.pending.count - 1
  let oldGeneration = controller.sidebarAnimationGeneration
  controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
  check(controller.sidebarAnimationGeneration > oldGeneration, "Closing invalidates the sidebar generation")
  ChromeAnimations.complete(pendingSidebar)
  check(controller.sidebarAnimationState == .hidden && controller.hideControlTimer == nil && controller.sideBarView.subviews.isEmpty,
        "A sidebar-open completion cannot mark a closed window shown or restart its timer")
  controller.showUI()
  ChromeAnimations.drain()
  check(controller.animationState == .shown && controller.sidebarAnimationState == .hidden,
        "Reopening a closed window cannot retain an in-progress sidebar animation")
  check(controller.hideUI(), "Reopened video can auto-hide without a stale sidebar transition blocking it")
}

withFixture { controller in
  controller.showPlaylistSidebar()
  ChromeAnimations.drain()
  controller.beginControlInteraction()
  controller.beginControlInteraction()
  controller.showSettingsSidebar(force: true)
  let pendingSwitchClose = ChromeAnimations.pending.count - 1
  controller.invalidateChromeOnClose()
  controller.window!.testVisible = false
  check(controller.controlInteractionDepth == 0 && controller.sideBarStatus == .hidden && !controller.sidebarAutoHidden,
        "Close invalidation clears interaction depth and remembered sidebar intent")
  controller.endControlInteraction()
  ChromeAnimations.complete(pendingSwitchClose)
  ChromeAnimations.drain()
  check(controller.hideControlTimer == nil && controller.sideBarView.subviews.isEmpty && controller.sidebarAnimationState == .hidden,
        "Late release and pending sidebar-switch callbacks cannot revive a closed window")
  check(controller.sideBarView.isHidden && controller.sideBarView.alphaValue == 1
          && controller.sideBarRightConstraint.constant == -controller.sideBarWidthConstraint.constant,
        "Close invalidation resets sidebar visibility, opacity, and placement for window reuse")
}

withFixture { controller in
  Preference.timeout = .nan
  controller.createTimer()
  let fallback = controller.hideControlTimer!
  check(abs(fallback.fireDate.timeIntervalSinceNow - 2.5) < 0.2, "The actual timer uses the finite delay fallback")
  Preference.timeout = -10
  controller.updateTimer()
  check(!fallback.isValid && abs(controller.hideControlTimer!.fireDate.timeIntervalSinceNow - 0.5) < 0.2,
        "Replacing a timer invalidates the old instance and clamps a negative delay")
  controller.player.disableUI = true
  controller.updateTimer()
  check(controller.hideControlTimer == nil, "Disabled UI cannot schedule an idle timer")
  controller.animationState = .hidden
  controller.showUI(force: true)
  check(controller.animationState == .hidden, "Disabled UI cannot be revived by a forced show")
}

let defaults = ChromeDefaults.value
defaults.set(0, forKey: "oscPosition")
defaults.set(false, forKey: "enableControlBarAutoHide")
defaults.set(false, forKey: "showRemainingTime")
defaults.set("preserved", forKey: "unrelatedPreference")
PlayerChromePolicy.migratePreferences(defaults)
check(defaults.integer(forKey: "oscPosition") == 2 && defaults.bool(forKey: "enableControlBarAutoHide") && defaults.bool(forKey: "showRemainingTime"),
      "The production upgrade moves floating controls to bottom-edge defaults")
check(defaults.integer(forKey: PlayerChromePolicy.migrationKey) == 1 && defaults.string(forKey: "unrelatedPreference") == "preserved",
      "Migration records its version without modifying unrelated preferences")
defaults.set(1, forKey: "oscPosition")
defaults.set(false, forKey: "enableControlBarAutoHide")
defaults.set(false, forKey: "showRemainingTime")
PlayerChromePolicy.migratePreferences(defaults)
check(defaults.integer(forKey: "oscPosition") == 1 && !defaults.bool(forKey: "enableControlBarAutoHide") && !defaults.bool(forKey: "showRemainingTime"),
      "Repeated migrations preserve subsequent user changes")
defaults.set(2, forKey: PlayerChromePolicy.migrationKey)
PlayerChromePolicy.migratePreferences(defaults)
check(defaults.integer(forKey: PlayerChromePolicy.migrationKey) == 2 && defaults.integer(forKey: "oscPosition") == 1,
      "An older migration never downgrades a future preference version")

withFixture { controller in
  let window = controller.window!
  let parent = NSView(frame: NSRect(x: 100, y: 100, width: 100, height: 100))
  let child = NSView(frame: NSRect(x: 20, y: 20, width: 100, height: 100))
  if #available(macOS 14.0, *) { parent.clipsToBounds = true }
  window.contentView!.addSubview(parent)
  parent.addSubview(child)
  let inside = NSPoint(x: 140, y: 140)
  check(PlayerChromePolicy.contains(inside, in: child, window: window), "Visible nested controls are hit-tested using window coordinates")
  check(!PlayerChromePolicy.contains(NSPoint(x: 350, y: 250), in: controller.fragSliderView, window: window),
        "An unclipped view's expanded visibleRect cannot extend its hit target beyond its own bounds")
  check(!PlayerChromePolicy.contains(NSPoint(x: 350, y: 250), in: controller.subPopoverView, window: window),
        "A zero-size view cannot intercept the full window through its expanded visibleRect")
  check(!PlayerChromePolicy.contains(NSPoint(x: 210, y: 140), in: child, window: window), "Clipped child content outside an ancestor cannot intercept the video")
  parent.isHidden = true
  check(!PlayerChromePolicy.contains(inside, in: child, window: window), "A hidden ancestor disables its child's hit target")
  parent.isHidden = false
  child.isHidden = true
  check(!PlayerChromePolicy.contains(inside, in: child, window: window), "A hidden control is not hit")
  child.isHidden = false
  parent.alphaValue = 0.01
  check(!PlayerChromePolicy.contains(inside, in: child, window: window), "Nearly-transparent ancestors do not block auto-hide")
  parent.alphaValue = 1
  child.alphaValue = 0
  check(!PlayerChromePolicy.contains(inside, in: child, window: window), "Transparent controls do not block video interaction")
  child.alphaValue = 1
  let other = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
  other.isReleasedWhenClosed = false
  check(!PlayerChromePolicy.contains(inside, in: child, window: other), "A view belonging to another window is not hit")
  check(!PlayerChromePolicy.contains(inside, in: nil, window: window) && !PlayerChromePolicy.contains(inside, in: child, window: nil),
        "Missing views and windows are not hit")
  child.removeFromSuperview()
  check(!PlayerChromePolicy.contains(inside, in: child, window: window), "Detached views cannot retain stale hit targets")
  other.close()
}

for value in [Double.nan, .infinity, -.infinity] {
  check(PlayerChromePolicy.hideDelay(value) == 2.5, "Non-finite auto-hide delay uses the safe default")
}
for value in [-100.0, -0.1, 0, 0.49] {
  check(PlayerChromePolicy.hideDelay(value) == 0.5, "Small and negative auto-hide delays clamp to half a second")
}
check(PlayerChromePolicy.hideDelay(1.25) == 1.25 && PlayerChromePolicy.hideDelay(60) == 60,
      "Finite in-range delays retain their configured value")
check(PlayerChromePolicy.hideDelay(1000) == 60, "Excessive auto-hide delays clamp to one minute")
print("Player chrome lifecycle checks passed: \(checks)")
