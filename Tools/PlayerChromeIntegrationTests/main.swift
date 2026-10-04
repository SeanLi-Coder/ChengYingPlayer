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
let restartProbe = CommandLine.arguments.count == 8 && CommandLine.arguments[5] == "--read-height"
let preferenceSuite = restartProbe ? CommandLine.arguments[6] : "org.chengying.tests.PlaylistHeight.\(UUID().uuidString)"
Preference.configureSuite(preferenceSuite)
let fixture = try ChromeFixture(xib: URL(fileURLWithPath: CommandLine.arguments[1]))
let controller = try LayoutController(fixture: fixture)
let window = controller.window!
window.orderFront(nil)
let content = window.contentView!
func heightGeometry(_ controller: LayoutController, stage: String) {
  let contentBounds = controller.window?.contentView?.bounds ?? .zero
  print("HEIGHT LAYOUT \(stage): content=\(contentBounds) sidebar=\(controller.sideBarView.frame) " +
        "maximum=\(controller.maximumPlaylistHeight) preferred=\(controller.preferredPlaylistHeight) " +
        "physicalScreen=\(controller.window?.screen?.visibleFrame ?? .zero)")
}
let originals = [controller.fragSliderView!, controller.fragControlView!, controller.fragToolbarView!, controller.fragVolumeView!]
let playlistFixture = try ChromeFixture(xib: URL(fileURLWithPath: CommandLine.arguments[2]))
let playlist = try PlaylistLayoutController(fixture: playlistFixture)
controller.playlistView = playlist
controller.sideBarView.addSubview(playlist.view)
controller.sidebarContentBottomConstraint = playlist.view.bottomAnchor.constraint(equalTo: controller.sideBarView.bottomAnchor)
NSLayoutConstraint.activate([
  playlist.view.leadingAnchor.constraint(equalTo: controller.sideBarView.leadingAnchor),
  playlist.view.trailingAnchor.constraint(equalTo: controller.sideBarView.trailingAnchor),
  playlist.view.topAnchor.constraint(equalTo: controller.sideBarView.topAnchor),
  controller.sidebarContentBottomConstraint!,
])
if restartProbe {
  let expected = CGFloat(Double(CommandLine.arguments[7])!)
  (window as! ChromeLayoutWindow).allowsOffscreenLayout = true
  window.setContentSize(NSSize(width: 900, height: 900))
  controller.setupOnScreenController(withPosition: .bottom)
  content.layoutSubtreeIfNeeded()
  heightGeometry(controller, stage: "process-restart")
  check(near(content.bounds.height, 900), "The process-restart fixture provides the full 900-point layout surface")
  check(near(controller.preferredPlaylistHeight, expected), "A fresh process reads the saved playlist height through the production preference getter")
  check(near(controller.sideBarView.frame.height, expected), "A fresh native controller lays out the remembered height after process restart")
  check(controller.sidebarResizeHandle?.isHidden == false, "A restarted playlist retains its native resize handle")
  window.close()
  print("RESTART RESULT: \(checks) checks, \(failures) failures")
  exit(failures == 0 ? 0 : 1)
}
let mediaFixture = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true).standardizedFileURL
try FileManager.default.createDirectory(at: mediaFixture, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: mediaFixture.appendingPathComponent("Season 2", isDirectory: true),
                                       withIntermediateDirectories: true)
for index in 1...6 {
  try Data([UInt8(index)]).write(to: mediaFixture.appendingPathComponent("Sample Video \(index).mp4"))
}
playlist.player.info.currentURL = mediaFixture.appendingPathComponent("Sample Video 1.mp4")
playlist.syncFolderBrowser()
let loadDeadline = Date().addingTimeInterval(5)
while playlist.folderBrowser.isLoading && Date() < loadDeadline {
  _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
}
check(!playlist.folderBrowser.isLoading && playlist.folderBrowser.visibleEntries.count == 7,
      "The integrated production folder browser loads only the generated temporary media fixture")
func selectBrowserMode(_ segment: Int) {
  playlist.browserModeControl.selectedSegment = segment
  check(NSApp.sendAction(playlist.browserModeControl.action!, to: playlist.browserModeControl.target,
                        from: playlist.browserModeControl),
        "The real sidebar mode control dispatches its production action")
  content.layoutSubtreeIfNeeded()
}

for size in [NSSize(width: 285, height: 120), NSSize(width: 320, height: 240), NSSize(width: 320, height: 380),
             NSSize(width: 640, height: 400), NSSize(width: 1920, height: 1080)] {
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
        check(controller.sideBarView.frame.height <= controller.preferredPlaylistHeight + 0.6 && controller.sideBarView.frame.height >= 251.4,
              "\(label): sidebar height stays within its intended bounds")
        check(controller.sideBarView.frame.minY >= footer.frame.maxY + 5.4,
              "\(label): sidebar cannot extend into the footer or below the video")
        check(controller.sideBarView.frame.maxY <= corner.frame.minY - 5.4,
              "\(label): sidebar stays below the corner toolbar")
        check(!controller.sideBarView.hasAmbiguousLayout && !footer.hasAmbiguousLayout && !corner.hasAmbiguousLayout,
              "\(label): the integrated edge layout has no ambiguous containers")
        check(window.contentMinSize == controller.minSize && content.bounds.width >= controller.minSize.width && content.bounds.height >= controller.minSize.height,
              "\(label): switching to edge mode expands undersized windows to the production content minimum")
        check(content.bounds.width <= max(controller.minSize.width, size.width) + 0.6 && content.bounds.height <= max(controller.minSize.height, size.height) + 0.6,
              "\(label): preferred sidebar height never expands the requested video window beyond its minimum")
        selectBrowserMode(1)
        let visibleHeight = playlist.playlistTableView.enclosingScrollView!.contentView.bounds.height
        print("PLAYLIST \(label): sidebar=\(controller.sideBarView.frame.height) header=\(playlist.tabHeightConstraint.constant) listViewport=\(visibleHeight) row=\(playlist.playlistTableView.rowHeight)")
        check(playlist.useCompactTabHeight && near(playlist.tabHeightConstraint.constant, 32),
              "\(label): edge mode uses the actual compact playlist header")
        check(!playlist.playlistTableView.isHiddenOrHasHiddenAncestor && playlist.folderBrowser.isHidden &&
              visibleHeight >= 44 && near(playlist.playlistTableView.rowHeight, 44),
              "\(label): the real queue layout including its mode switch leaves at least one full 44-point row")
        if !fullscreen {
          try snapshot(content, name: "player-chrome-integrated-\(Int(size.width))-\(Int(size.height))-queue")
        }
        selectBrowserMode(0)
        let folderVisibleHeight = playlist.folderBrowser.tableView.enclosingScrollView!.contentView.bounds.height
        print("FOLDER \(label): sidebar=\(controller.sideBarView.frame.height) folderViewport=\(folderVisibleHeight) row=\(playlist.folderBrowser.tableView.rowHeight)")
        check(!playlist.folderBrowser.isHiddenOrHasHiddenAncestor && playlist.playlistTableView.isHiddenOrHasHiddenAncestor &&
              folderVisibleHeight >= 58 && near(playlist.folderBrowser.tableView.rowHeight, 58),
              "\(label): the actual folder header, sort, filter, and mode switch leave at least one full 58-point row")
        check(!playlist.browserModeControl.hasAmbiguousLayout && !playlist.folderBrowser.hasAmbiguousLayout &&
              !playlist.folderBrowser.tableView.enclosingScrollView!.hasAmbiguousLayout,
              "\(label): the extracted folder integration has no ambiguous mode or browser containers")
        if !fullscreen {
          try snapshot(content, name: "player-chrome-integrated-\(Int(size.width))-\(Int(size.height))")
        }
      } else {
        check(controller.edgeControls == nil && controller.cornerControls == nil,
              "\(label): legacy modes remove both edge containers")
        check(controller.originalSidebarVerticalConstraints.allSatisfy(\.isActive),
              "\(label): legacy full-height sidebar constraints are restored")
        let legacyFolderHeight = playlist.folderBrowser.tableView.enclosingScrollView!.contentView.bounds.height
        print("LEGACY FOLDER \(label): content=\(content.bounds.height) folderViewport=\(legacyFolderHeight)")
        check(legacyFolderHeight >= playlist.folderBrowser.tableView.rowHeight,
              "\(label): returning from edge mode to a legacy layout keeps at least one visible folder row")
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

func mouseEvent(_ type: NSEvent.EventType, point: NSPoint, eventWindow: NSWindow = window) -> NSEvent {
  NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: eventWindow.windowNumber, context: nil, eventNumber: 110,
                    clickCount: 1, pressure: 0)!
}
func prepareResizablePlaylist(size: NSSize = NSSize(width: 900, height: 900)) {
  controller.sideBarStatus = .playlist
  controller.fsState.isFullscreen = false
  controller.setupOnScreenController(withPosition: .floating)
  (window as! ChromeLayoutWindow).allowsOffscreenLayout = true
  window.setContentSize(size)
  controller.setupOnScreenController(withPosition: .bottom)
  controller.sideBarView.isHidden = false
  controller.sideBarView.alphaValue = 1
  controller.updateSidebarResizeHandle()
  content.layoutSubtreeIfNeeded()
}
func beginHandleDrag() -> (PlayerSidebarResizeHandle, NSPoint) {
  guard let handle = controller.sidebarResizeHandle else { fatalError("The production resize handle was not installed") }
  let point = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
  check(content.hitTest(content.convert(point, from: nil)) === handle,
        "Native hit testing routes the visible lower-edge grip to the production resize handle")
  handle.mouseDown(with: mouseEvent(.leftMouseDown, point: point))
  return (handle, point)
}

prepareResizablePlaylist()
let defaultHeight = controller.preferredPlaylistHeight
heightGeometry(controller, stage: "default")
check(near(content.bounds.width, 900) && near(content.bounds.height, 900),
      "The height-memory fixture supplies an actual 900-point surface independent of the physical CI screen")
check(near(defaultHeight, 600) && near(controller.sideBarView.frame.height, defaultHeight),
      "A fresh playlist uses the longer production default in a sufficiently large window")
check(Preference.defaults.persistentDomain(forName: preferenceSuite)?[Preference.Key.playlistHeight.rawValue] == nil,
      "Laying out the default sidebar does not manufacture an explicit saved height")
let contentSizeBeforeDrag = content.bounds.size
let widthBeforeDrag = controller.sideBarWidthConstraint.constant
let topBeforeDrag = controller.sideBarView.frame.maxY
let beganBeforeDrag = controller.controlInteractionBegins
let endedBeforeDrag = controller.controlInteractionEnds
let (resizeHandle, initialPoint) = beginHandleDrag()
check(controller.controlInteractionDepth == 1 && controller.controlInteractionBegins == beganBeforeDrag + 1,
      "A real lower-edge mouse press protects the chrome while resizing starts")
resizeHandle.mouseDown(with: mouseEvent(.leftMouseDown, point: initialPoint))
check(controller.controlInteractionDepth == 1 && controller.controlInteractionBegins == beganBeforeDrag + 1,
      "A repeated lower-edge press cannot create nested resize interactions")
let draggedPoint = NSPoint(x: initialPoint.x, y: initialPoint.y - 90)
resizeHandle.mouseDragged(with: mouseEvent(.leftMouseDragged, point: draggedPoint))
content.layoutSubtreeIfNeeded()
heightGeometry(controller, stage: "dragged")
check(near(controller.sideBarView.frame.height, defaultHeight + 90) && near(controller.sideBarView.frame.maxY, topBeforeDrag),
      "Dragging the native lower edge downward extends the sidebar while its top stays anchored")
check(content.bounds.size == contentSizeBeforeDrag && near(controller.sideBarWidthConstraint.constant, widthBeforeDrag),
      "A height drag changes neither video-window size nor remembered sidebar width")
check(Preference.defaults.persistentDomain(forName: preferenceSuite)?[Preference.Key.playlistHeight.rawValue] == nil,
      "Intermediate mouse movements do not save partial resize preferences")
resizeHandle.mouseUp(with: mouseEvent(.leftMouseUp, point: draggedPoint))
let savedHeight = Preference.double(for: .playlistHeight)
check(near(CGFloat(savedHeight), defaultHeight + 90) && controller.controlInteractionDepth == 0 &&
      controller.controlInteractionEnds == endedBeforeDrag + 1,
      "The real mouse release commits height once and releases interaction protection")
resizeHandle.mouseUp(with: mouseEvent(.leftMouseUp, point: draggedPoint))
check(controller.controlInteractionEnds == endedBeforeDrag + 1 && Preference.double(for: .playlistHeight) == savedHeight,
      "A late duplicate mouse release cannot repeat callbacks or change the saved preference")
selectBrowserMode(1)
let queueHeight = playlist.playlistTableView.enclosingScrollView!.contentView.bounds.height
try snapshot(content, name: "sidebar-remembered-height-queue")
selectBrowserMode(0)
let folderHeight = playlist.folderBrowser.tableView.enclosingScrollView!.contentView.bounds.height
try snapshot(content, name: "sidebar-remembered-height-folder")
check(queueHeight > 400 && folderHeight > 400 && near(controller.sideBarView.frame.height, CGFloat(savedHeight)),
      "Both playback-queue and folder modes share the stretched sidebar and usable table viewport")
check(controller.sidebarContentBottomConstraint?.constant == -12 &&
      !playlist.view.frame.intersects(resizeHandle.frame),
      "The production lower-edge grip receives its reserved strip outside the playlist content")

window.setContentSize(NSSize(width: 320, height: controller.minSize.height))
controller.updateEdgeControlsLayout()
content.layoutSubtreeIfNeeded()
let clampedHeight = controller.sideBarView.frame.height
heightGeometry(controller, stage: "small-window-clamp")
check(clampedHeight < CGFloat(savedHeight) && controller.sideBarView.frame.minY >= controller.edgeControls!.frame.maxY + 5.4,
      "A smaller video window clamps the remembered sidebar above the playback footer")
check(Preference.double(for: .playlistHeight) == savedHeight,
      "Automatic small-window clamping keeps the user's larger saved preference intact")
window.setContentSize(NSSize(width: 900, height: 900))
controller.updateEdgeControlsLayout()
content.layoutSubtreeIfNeeded()
heightGeometry(controller, stage: "large-window-restored")
check(near(controller.sideBarView.frame.height, CGFloat(savedHeight)),
      "Growing the window restores the preferred height instead of remembering the temporary clamp")
controller.fsState.isFullscreen = true
controller.updateEdgeControlsLayout()
content.layoutSubtreeIfNeeded()
heightGeometry(controller, stage: "fullscreen-layout")
check(near(controller.sideBarView.frame.height, CGFloat(savedHeight)) &&
      controller.sideBarView.frame.maxY <= controller.cornerControls!.frame.minY - 5.4,
      "Fullscreen geometry applies the remembered height below its shifted corner toolbar")
check(Preference.double(for: .playlistHeight) == savedHeight,
      "Fullscreen layout changes do not save a different height")

let (boundedHandle, boundedPoint) = beginHandleDrag()
boundedHandle.mouseDragged(with: mouseEvent(.leftMouseDragged, point: NSPoint(x: boundedPoint.x, y: -10_000)))
content.layoutSubtreeIfNeeded()
check(controller.sideBarView.frame.minY >= controller.edgeControls!.frame.maxY + 5.4 &&
      controller.sideBarView.frame.maxY <= controller.cornerControls!.frame.minY - 5.4,
      "A drag far beyond the window remains between the toolbar and footer")
boundedHandle.mouseDragged(with: mouseEvent(.leftMouseDragged, point: NSPoint(x: boundedPoint.x, y: 10_000)))
content.layoutSubtreeIfNeeded()
check(controller.sideBarView.frame.height >= 251.4,
      "Dragging far upward preserves the production minimum sidebar height")
boundedHandle.mouseUp(with: mouseEvent(.leftMouseUp, point: boundedPoint))
check(controller.controlInteractionDepth == 0, "An out-of-window drag still ends its protected interaction")
Preference.set(savedHeight, for: .playlistHeight)
prepareResizablePlaylist()

let (cancelledHandle, cancelPoint) = beginHandleDrag()
cancelledHandle.mouseDragged(with: mouseEvent(.leftMouseDragged, point: NSPoint(x: cancelPoint.x, y: cancelPoint.y - 30)))
controller.setupOnScreenController(withPosition: .floating)
content.layoutSubtreeIfNeeded()
check(controller.controlInteractionDepth == 0 && Preference.double(for: .playlistHeight) == savedHeight,
      "A mode switch cancels active lower-edge tracking without saving the interrupted drag")
cancelledHandle.mouseUp(with: mouseEvent(.leftMouseUp, point: cancelPoint))
check(controller.controlInteractionDepth == 0 && Preference.double(for: .playlistHeight) == savedHeight,
      "The old grip's late release cannot commit after its mode has been removed")
prepareResizablePlaylist()
controller.sideBarStatus = .settings
controller.updateEdgeControlsLayout()
controller.updateSidebarResizeHandle()
content.layoutSubtreeIfNeeded()
check(controller.sidebarResizeHandle == nil && near(controller.sideBarView.frame.height, 400),
      "Settings retains its compact height and does not expose the playlist-only drag grip")
check(Preference.double(for: .playlistHeight) == savedHeight, "Opening settings preserves the saved playlist height")
prepareResizablePlaylist()

let restoredController = try LayoutController(fixture: ChromeFixture(xib: URL(fileURLWithPath: CommandLine.arguments[1])))
restoredController.playlistView = try PlaylistLayoutController(fixture: ChromeFixture(xib: URL(fileURLWithPath: CommandLine.arguments[2])))
(restoredController.window as! ChromeLayoutWindow).allowsOffscreenLayout = true
restoredController.window!.setContentSize(NSSize(width: 900, height: 900))
restoredController.setupOnScreenController(withPosition: .bottom)
restoredController.window!.contentView!.layoutSubtreeIfNeeded()
heightGeometry(restoredController, stage: "new-window")
check(near(restoredController.window!.contentView!.bounds.height, 900),
      "A new-window restoration fixture also supplies a full 900-point layout surface")
check(near(restoredController.sideBarView.frame.height, CGFloat(savedHeight)),
      "Opening another native player window restores the same global saved playlist height")
restoredController.window!.close()
check(Preference.defaults.synchronize(), "Flush only the isolated test preference suite before restart verification")
let process = Process()
process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
process.arguments = Array(CommandLine.arguments[1...4]) + ["--read-height", preferenceSuite, String(savedHeight)]
let restartOutput = Pipe()
process.standardOutput = restartOutput
process.standardError = restartOutput
try process.run()
let restartDeadline = Date().addingTimeInterval(15)
while process.isRunning && Date() < restartDeadline {
  _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
}
if process.isRunning { process.terminate() }
check(!process.isRunning, "The isolated process-restart probe exits within its deadline")
process.waitUntilExit()
let restartText = String(data: restartOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
print(restartText)
check(process.terminationStatus == 0 && restartText.contains("RESTART RESULT: 4 checks, 0 failures"),
      "Saved sidebar height survives a fresh process, native controller, and AppKit layout")

let (closingHandle, closingPoint) = beginHandleDrag()
closingHandle.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                          point: NSPoint(x: closingPoint.x, y: closingPoint.y - 25)))
window.close()
check(controller.controlInteractionDepth == 0 && Preference.double(for: .playlistHeight) == savedHeight,
      "Closing the actual native window cancels an outstanding drag without saving its partial height")
let endedAfterClose = controller.controlInteractionEnds
closingHandle.mouseUp(with: mouseEvent(.leftMouseUp, point: closingPoint))
check(controller.controlInteractionEnds == endedAfterClose && Preference.double(for: .playlistHeight) == savedHeight,
      "A release arriving after window closure cannot resume tracking or overwrite the saved height")

for invalid in [Double.nan, Double.infinity, -100, 0] {
  Preference.set(invalid, for: .playlistHeight)
  check(near(controller.preferredPlaylistHeight, defaultHeight),
        "An invalid isolated height preference falls back to the production default")
}
Preference.set(savedHeight, for: .playlistHeight)
Preference.defaults.removePersistentDomain(forName: preferenceSuite)
Preference.defaults.synchronize()
window.close()
print("RESULT: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
