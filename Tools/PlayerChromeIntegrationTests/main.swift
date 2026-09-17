import Cocoa

var checks = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  checks += 1
  if condition() { print("PASS: \(message)") } else { failures += 1; print("FAIL: \(message)") }
}
func near(_ left: CGFloat, _ right: CGFloat) -> Bool { abs(left - right) < 0.6 }
func snapshot(_ content: NSView, name: String) throws {
  content.window?.displayIfNeeded()
  RunLoop.current.run(until: Date().addingTimeInterval(0.03))
  content.layoutSubtreeIfNeeded()
  let backing = content.convertToBacking(content.bounds)
  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
  content.cacheDisplay(in: content.bounds, to: bitmap)
  let data = bitmap.representation(using: .png, properties: [:])!
  check(bitmap.pixelsWide == Int(ceil(backing.width)) && bitmap.pixelsHigh == Int(ceil(backing.height)) && data.count > 1024,
        "\(name): the native integration screenshot covers actual content/backing bounds")
  try data.write(to: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true).appendingPathComponent(name + ".png"))
}
setbuf(stdout, nil)
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let fixture = try ChromeFixture(xib: URL(fileURLWithPath: CommandLine.arguments[1]))
let controller = try LayoutController(fixture: fixture)
let window = controller.window!
window.orderFront(nil)
let content = window.contentView!
let originals = [controller.fragSliderView!, controller.fragControlView!, controller.fragToolbarView!, controller.fragVolumeView!]
let playlistFixture = try ChromeFixture(xib: URL(fileURLWithPath: CommandLine.arguments[2]))
let playlist = try PlaylistLayoutController(fixture: playlistFixture)
controller.playlistView = playlist
controller.sideBarView.addSubview(playlist.view)
NSLayoutConstraint.activate([
  playlist.view.leadingAnchor.constraint(equalTo: controller.sideBarView.leadingAnchor),
  playlist.view.trailingAnchor.constraint(equalTo: controller.sideBarView.trailingAnchor),
  playlist.view.topAnchor.constraint(equalTo: controller.sideBarView.topAnchor),
  playlist.view.bottomAnchor.constraint(equalTo: controller.sideBarView.bottomAnchor),
])

for size in [NSSize(width: 285, height: 120), NSSize(width: 320, height: 240), NSSize(width: 640, height: 400), NSSize(width: 1920, height: 1080)] {
  controller.setupOnScreenController(withPosition: .floating)
  window.setContentSize(size)
  for fullscreen in [false, true] {
    controller.fsState.isFullscreen = fullscreen
    for position in [Preference.OSCPosition.bottom, .floating, .top, .bottom] {
      controller.setupOnScreenController(withPosition: position)
      controller.updateEdgeControlsLayout()
      content.layoutSubtreeIfNeeded()
      let label = "\(Int(size.width))x\(Int(size.height)) fullscreen=\(fullscreen) \(position)"
      check(near(controller.videoView.frame.width, content.bounds.width) && near(controller.videoView.frame.height, content.bounds.height),
            "\(label): chrome never shrinks the video surface")
      check(Set(controller.fadeableViews.map(ObjectIdentifier.init)).count == controller.fadeableViews.count,
            "\(label): no duplicate fadeable controls survive mode switches")
      if position == .bottom {
        let footer = controller.edgeControls!
        let corner = controller.cornerControls!
        print("LAYOUT \(label): content=\(content.bounds) footer=\(footer.frame) corner=\(corner.frame) sidebar=\(controller.sideBarView.frame)")
        check(near(footer.frame.minY, 0) && near(footer.frame.height, 62) && near(footer.frame.width, content.bounds.width),
              "\(label): the real setup method pins the footer to the bottom")
        check(near(corner.frame.maxX, content.bounds.maxX - 8) && near(corner.frame.maxY, content.bounds.maxY - (fullscreen ? 10 : 28)),
              "\(label): the real setup method pins toolbar at the upper-right")
        check(originals.allSatisfy { $0.isDescendant(of: content) }, "\(label): every original fragment returns after legacy-mode round trips")
        let buttons = controller.fragToolbarView.views.compactMap { $0 as? NSButton }
        print("TOOLBAR \(label): frame=\(controller.fragToolbarView.frame) hidden=\(controller.fragToolbarView.isHidden) " +
              "ancestorHidden=\(controller.fragToolbarView.isHiddenOrHasHiddenAncestor) alpha=\(controller.fragToolbarView.alphaValue) " +
              "detached=\(controller.fragToolbarView.detachedViews.count) cornerAlpha=\(corner.alphaValue) " +
              "buttonFrames=\(buttons.map(\.frame))")
        check(buttons.allSatisfy { $0.frame.width >= 20 && $0.frame.height >= 24 && !$0.isHidden },
              "\(label): every rebuilt toolbar button has visible native geometry")
        check(buttons.allSatisfy { !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0.99 },
              "\(label): a legacy detached toolbar cannot remain hidden inside the new corner strip")
        check(originals.allSatisfy { !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0.99 },
              "\(label): every reused top-level fragment clears legacy stack hidden state")
        check(controller.fragToolbarView.frame.height >= 24 && controller.fragToolbarView.detachedViews.isEmpty &&
              buttons.allSatisfy { controller.fragToolbarView.bounds.contains($0.alignmentRect(forFrame: $0.frame)) },
              "\(label): rebuilt icons remain inside a nonzero toolbar instead of clipping outside an empty stack")
        check(buttons.count == 4 && buttons.suffix(2).map(\.tag) == [Preference.ToolBarButton.settings.rawValue, Preference.ToolBarButton.playlist.rawValue],
              "\(label): toolbar has one information entry and settings/file-list at the right")
        check(controller.sideBarView.frame.height <= 400.6 && controller.sideBarView.frame.height >= 139.4,
              "\(label): sidebar height stays within its intended bounds")
        check(controller.sideBarView.frame.minY >= footer.frame.maxY + 5.4,
              "\(label): sidebar cannot extend into the footer or below the video")
        check(controller.sideBarView.frame.maxY <= corner.frame.minY - 5.4,
              "\(label): sidebar stays below the corner toolbar")
        check(!controller.sideBarView.hasAmbiguousLayout && !footer.hasAmbiguousLayout && !corner.hasAmbiguousLayout,
              "\(label): the integrated edge layout has no ambiguous containers")
        check(window.contentMinSize == NSSize(width: 320, height: 280) && content.bounds.width >= 320 && content.bounds.height >= 280,
              "\(label): switching to edge mode expands undersized windows to the production content minimum")
        check(content.bounds.width <= max(320, size.width) + 0.6 && content.bounds.height <= max(280, size.height) + 0.6,
              "\(label): preferred sidebar height never expands the requested video window beyond its minimum")
        let visibleHeight = playlist.playlistTableView.enclosingScrollView!.contentView.bounds.height
        print("PLAYLIST \(label): sidebar=\(controller.sideBarView.frame.height) header=\(playlist.tabHeightConstraint.constant) listViewport=\(visibleHeight) row=\(playlist.playlistTableView.rowHeight)")
        check(playlist.useCompactTabHeight && near(playlist.tabHeightConstraint.constant, 32),
              "\(label): edge mode uses the actual compact playlist header")
        check(visibleHeight >= playlist.playlistTableView.rowHeight,
              "\(label): the real playlist headers, sorting controls, and footer leave at least one full row")
        if !fullscreen {
          try snapshot(content, name: "player-chrome-integrated-\(Int(size.width))-\(Int(size.height))")
        }
      } else {
        check(controller.edgeControls == nil && controller.cornerControls == nil,
              "\(label): legacy modes remove both edge containers")
        check(controller.originalSidebarVerticalConstraints.allSatisfy(\.isActive),
              "\(label): legacy full-height sidebar constraints are restored")
      }
    }
  }
}
Preference.toolbarButtons = [1, 0, 7, 4, 2, 1, 0]
controller.setupOSCToolbarButtons(Preference.toolbarButtons.compactMap(Preference.ToolBarButton.init(rawValue:)))
content.layoutSubtreeIfNeeded()
let essentialButtons = controller.fragToolbarView.views.compactMap { $0 as? NSButton }
check(essentialButtons.count == 4 && essentialButtons.suffix(2).map(\.tag) == [0, 1],
      "Repeated settings/file-list preferences and retired features cannot duplicate essential corner entries")
Preference.toolbarButtons = [2, 3, 5, 6, 0, 1]
controller.setupOSCToolbarButtons(Preference.toolbarButtons.compactMap(Preference.ToolBarButton.init(rawValue:)))
content.layoutSubtreeIfNeeded()
check(controller.fragToolbarView.views.count == 7 && controller.cornerControls!.frame.width < 220,
      "The complete supported toolbar remains compact with real production icon sizing")
controller.fsState.isFullscreen = false
for type in [LayoutController.SidebarStatus.playlist, .settings, .plugins] {
  controller.sideBarStatus = type
  for position in [Preference.OSCPosition.floating, .top] {
    controller.setupOnScreenController(withPosition: .bottom)
    content.layoutSubtreeIfNeeded()
    controller.sidebarAutoHidden = true
    controller.sideBarView.isHidden = true
    controller.sideBarView.alphaValue = 0
    controller.setupOnScreenController(withPosition: position)
    content.layoutSubtreeIfNeeded()
    check(!controller.sideBarView.isHidden && controller.sideBarView.alphaValue == 1 && !controller.sidebarAutoHidden,
          "An auto-hidden \(type) sidebar becomes visible when switching to legacy \(position) mode")
    let shift: CGFloat
    switch type {
    case .playlist: shift = controller.playlistView.downShift
    case .settings: shift = controller.quickSettingView.downShift
    case .plugins: shift = controller.pluginView.downShift
    case .hidden: shift = -1
    }
    check(near(shift, controller.titleBarView.frame.height),
          "The \(type) sidebar follows the final \(position) titlebar height instead of the previous layout")
  }
}
window.close()
print("RESULT: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
