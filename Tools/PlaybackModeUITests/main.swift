import Cocoa

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}

let preferenceTitle = NSLocalizedString("jok-kc-HjX.title", tableName: "PrefGeneralViewController", comment: "Global repeat scope")
check(preferenceTitle != "jok-kc-HjX.title" && !preferenceTitle.contains("manually") &&
      !preferenceTitle.contains("手动") && !preferenceTitle.contains("主動"),
      "Preferences describe repeating for all videos in the current language")
let preferenceControl = NSButton(checkboxWithTitle: preferenceTitle, target: nil, action: nil)
check(preferenceControl.intrinsicContentSize.width <= 214,
      "The translated global-repeat preference label fits the existing checkbox")

let controller = PlaylistModeControllerUnderTest()
controller.view = PlaybackModeCanvas(frame: NSRect(x: 0, y: 0, width: 240, height: 435))
let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 240, height: 435), styleMask: [.titled],
                      backing: .buffered, defer: false)
window.appearance = NSAppearance(named: .aqua)
window.contentView = controller.view
for child in [controller.browserModeControl, controller.sortControls, controller.folderBrowser] {
  child.translatesAutoresizingMaskIntoConstraints = false
  controller.view.addSubview(child)
}
NSLayoutConstraint.activate([
  controller.browserModeControl.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 6),
  controller.browserModeControl.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
  controller.browserModeControl.heightAnchor.constraint(equalToConstant: 24),
  controller.sortControls.topAnchor.constraint(equalTo: controller.browserModeControl.bottomAnchor, constant: 6),
  controller.sortControls.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
  controller.sortControls.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
  controller.sortControls.heightAnchor.constraint(equalToConstant: 38),
  controller.folderBrowser.topAnchor.constraint(equalTo: controller.browserModeControl.bottomAnchor, constant: 6),
  controller.folderBrowser.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
  controller.folderBrowser.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
  controller.folderBrowser.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor)
])
controller.queuePresentationViews = [controller.sortControls]
controller.installPlaybackModeControls()
controller.view.layoutSubtreeIfNeeded()
let popup = controller.playbackModePopup
check(popup.numberOfItems == 3, "The visible popup offers all three modes")
check(popup.identifier?.rawValue == "playlist.playback-mode", "The popup has a stable accessibility identifier")
check(popup.accessibilityLabel() == PlaybackModeMenu.accessibilityLabel,
      "VoiceOver identifies the playback mode control")
check(popup.itemTitles.allSatisfy { !$0.hasPrefix("playback_mode.") }, "Every mode label is localized")
check(popup.frame.width + 1 >= popup.intrinsicContentSize.width,
      "All translated mode titles fit at the minimum 240-point sidebar width")
check(popup.superview!.frame.minX >= 0 && popup.superview!.frame.maxX <= controller.view.bounds.maxX,
      "Mode controls stay inside the narrow sidebar")
check(!popup.hasAmbiguousLayout && !popup.superview!.hasAmbiguousLayout,
      "The mode selector has an unambiguous layout")

if let snapshotPath = ProcessInfo.processInfo.environment["PLAYBACK_MODE_UI_SNAPSHOT_DIR"] {
  let destination = URL(fileURLWithPath: snapshotPath, isDirectory: true)
  try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
  let language = Bundle.main.preferredLocalizations.first ?? "en"
  for width in [240, 320] {
    window.setContentSize(NSSize(width: width, height: 435))
    controller.view.layoutSubtreeIfNeeded()
    guard let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) else {
      fatalError("Unable to create the playback mode UI snapshot")
    }
    if #available(macOS 11.0, *) {
      controller.view.effectiveAppearance.performAsCurrentDrawingAppearance {
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
      }
    } else {
      controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
    }
    let path = destination.appendingPathComponent("playback-mode-\(language)-\(width).png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: path)
    print("SNAPSHOT: \(path.path)")
  }
}

controller.browserPlaybackURL = URL(fileURLWithPath: "/synthetic-media/movie.mp4")
for browsing in [true, false] {
  controller.prefersFolderBrowser = browsing
  controller.updateBrowserMode()
  check(!popup.isHiddenOrHasHiddenAncestor, "Playback mode remains visible in either browser view")
}

for mode in PlaybackModeMenu.modes {
  let item = popup.itemArray.first { ($0.representedObject as? LoopMode) == mode }!
  popup.select(item)
  check(NSApp.sendAction(popup.action!, to: popup.target, from: popup), "AppKit dispatches the popup action")
  check(controller.player.mode == mode, "The popup applies the selected mode")
  check(popup.itemArray.filter { $0.state == .on }.count == 1 && item.state == .on,
        "Exactly the current playback mode is selected")
  check(popup.accessibilityValue() as? String == PlaybackModeMenu.title(for: mode),
        "VoiceOver reads the selected playback mode")
  check(controller.loopBtn.accessibilityValue() as? String == PlaybackModeMenu.title(for: mode),
        "The legacy loop button exposes the same current mode")
  check(popup.toolTip?.contains(PlaybackModeMenu.scopeDescription) == true,
        "The tooltip explains global persistence and independent A-B repeat")
  _ = NSApp.sendAction(popup.action!, to: popup.target, from: popup)
  check(controller.player.mode == mode, "Selecting the current mode is idempotent")
}

let context = PlaybackModeMenu.makeMenu(selected: .file, target: controller,
                                        action: #selector(PlaylistModeControllerUnderTest.selectLoopMode(_:)))
check(context.items.map(\.state) == [.off, .on, .off], "The loop-button menu checks the current mode")
for item in context.items {
  check(NSApp.sendAction(item.action!, to: item.target, from: item), "AppKit dispatches the loop-button menu action")
  check(controller.player.mode == item.representedObject as? LoopMode, "The loop-button menu applies its explicit mode")
}
let count = controller.player.selectedModes.count
controller.selectLoopMode(NSMenuItem(title: "Invalid", action: nil, keyEquivalent: ""))
check(controller.player.selectedModes.count == count, "An unrelated menu item cannot change playback mode")
controller.player.mode = .file
controller.updateLoopBtnStatus()
check(popup.selectedItem?.representedObject as? LoopMode == .file,
      "A mode change from another player refreshes the popup")

let mainMenu = MenuControllerUnderTest()
let abLoop = NSMenuItem(title: "A-B Loop", action: nil, keyEquivalent: "")
mainMenu.playbackMenu.addItem(abLoop)
mainMenu.playbackMenu.addItem(mainMenu.fileLoop)
mainMenu.playbackMenu.addItem(mainMenu.playlistLoop)
mainMenu.installPlaybackModeMenu()
mainMenu.installPlaybackModeMenu()
check(mainMenu.playbackMenu.items.count == 4 && mainMenu.playbackMenu.items.first === abLoop,
      "Playback menu setup is idempotent and preserves the independent A-B entry")
let actions = MainMenuActionHandler()
actions.player.mode = .playlist
check(NSApp.sendAction(mainMenu.noLoop!.action!, to: actions, from: mainMenu.noLoop!),
      "AppKit dispatches the main menu no-repeat action")
check(actions.player.mode == .off, "The main menu can explicitly disable both repeat modes")
for mode in PlaybackModeMenu.modes {
  actions.player.mode = mode
  mainMenu.updatePlaybackMode(player: actions.player)
  let entries = [mainMenu.noLoop!, mainMenu.fileLoop, mainMenu.playlistLoop]
  check(entries.filter { $0.state == .on }.count == 1,
        "The main menu checks exactly one playback mode")
}
actions.player.mode = .off
actions.menuFileLoop(mainMenu.fileLoop)
check(actions.player.mode == .file, "The existing file-loop action still enables file repeat")
actions.menuFileLoop(mainMenu.fileLoop)
check(actions.player.mode == .off, "The existing file-loop action still toggles off")
actions.menuPlaylistLoop(mainMenu.playlistLoop)
check(actions.player.mode == .playlist, "The existing playlist-loop action still enables playlist repeat")
actions.menuPlaylistLoop(mainMenu.playlistLoop)
check(actions.player.mode == .off, "The existing playlist-loop action still toggles off")
print("All \(checks) playback mode UI checks passed")
