import Cocoa

enum Preference {
  enum OSCPosition { case floating, top, bottom }
  enum Key { case controlBarPositionHorizontal, controlBarPositionVertical, controlBarToolbarButtons }
  static var toolbarButtons = [2, 0, 1]
  static func array(for key: Key) -> [Any]? { toolbarButtons }
  static func float(for key: Key) -> Float { 0.5 }
}

extension NSView {
  func roundCorners(withRadius radius: CGFloat) {
    wantsLayer = true
    layer?.cornerRadius = radius
    layer?.masksToBounds = true
  }
}

final class FloatingFixtureView: NSVisualEffectView {
  var isDragging = false
  lazy var xConstraint = NSLayoutConstraint(item: self, attribute: .width, relatedBy: .equal,
                                            toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 0)
  lazy var yConstraint = NSLayoutConstraint(item: self, attribute: .height, relatedBy: .equal,
                                            toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 0)
}

final class LayoutController: NSWindowController {
  struct FullscreenState { var isFullscreen = false }
  struct SidebarShift { var downShift: CGFloat = 0 }
  enum SidebarStatus { case hidden, playlist, settings, plugins }
  var quickSettingView = SidebarShift()
  var pluginView = SidebarShift()
  var playlistView: PlaylistLayoutController!
  var fsState = FullscreenState()
  var sideBarStatus = SidebarStatus.playlist
  var sidebarAutoHidden = false
  var oscIsInitialized = false
  var oscPosition = Preference.OSCPosition.bottom
  var isUsingEdgeControls: Bool { oscPosition == .bottom }
  var sidebarMaxWidth: CGFloat { max(window!.frame.width * 0.8, PlaylistMinWidth) }
  var currentControlBar: NSView?
  var edgeControls: PlayerEdgeControlsView?
  var cornerControls: PlayerCornerControlsView?
  var cornerTopConstraint: NSLayoutConstraint?
  var originalSidebarVerticalConstraints: [NSLayoutConstraint] = []
  var edgeSidebarConstraints: [NSLayoutConstraint] = []
  var oscFloatingLeadingTrailingConstraint: [NSLayoutConstraint]?
  var fadeableViews: [NSView] = []
  var shown = 0
  var timerUpdates = 0
  var titleBarHeightConstraint: NSLayoutConstraint!
  var oscTopMainViewTopConstraint: NSLayoutConstraint!
  var sideBarRightConstraint: NSLayoutConstraint!
  var sideBarWidthConstraint: NSLayoutConstraint!
  var fragControlViewMiddleButtons1Constraint: NSLayoutConstraint!
  var fragControlViewMiddleButtons2Constraint: NSLayoutConstraint!
  let titleBarView = NSVisualEffectView()
  let controlBarFloating = FloatingFixtureView()
  let controlBarBottom = NSVisualEffectView()
  let sideBarView = NSVisualEffectView()
  let videoView = ChromeSampleVideo()
  var oscFloatingTopView: NSStackView! = NSStackView()
  var oscFloatingBottomView: NSView! = NSView()
  var oscTopMainView: NSStackView! = NSStackView()
  var oscBottomMainView: NSStackView! = NSStackView()
  var fragSliderView: NSView!
  var fragControlView: NSStackView!
  var fragToolbarView: NSStackView!
  var fragVolumeView: NSView!
  var fragControlViewLeftView: NSView!
  var fragControlViewRightView: NSView!
  var fragControlViewMiddleView: NSView!
  var playSlider: NSSlider!

  init(fixture: ChromeFixture) throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    super.init(window: window)
    window.isReleasedWhenClosed = false
    window.contentMinSize = NSSize(width: 285, height: 120)
    let content = window.contentView!
    fragSliderView = try fixture.fragment("BE1-yC-oJL")
    fragControlView = try fixture.fragment("hDm-KI-3o4") as? NSStackView
    fragToolbarView = try fixture.fragment("KfP-G9-8pD") as? NSStackView
    fragVolumeView = try fixture.fragment("N3B-DL-XOA")
    fragControlViewLeftView = try fixture.fragment("8Ej-eH-OR9")
    fragControlViewRightView = try fixture.fragment("Xts-Pc-T8d")
    fragControlViewMiddleView = try fixture.fragment("Yv6-0K-6E4")
    [fragControlViewLeftView!, fragControlViewMiddleView!, fragControlViewRightView!].forEach { fragControlView.addView($0, in: .center) }
    fragControlViewMiddleButtons1Constraint = fragControlViewMiddleView.constraints.first { $0.identifier == "aEy-x5-Ctd" }!
    fragControlViewMiddleButtons2Constraint = fragControlViewMiddleView.constraints.first { $0.identifier == "WtE-JF-0m3" }!
    playSlider = fixture.view("eBP-6g-bAT") as? NSSlider
    for view in [videoView, titleBarView, controlBarBottom, controlBarFloating, sideBarView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(view)
    }
    for stack in [oscFloatingTopView!, oscTopMainView!, oscBottomMainView!] {
      stack.translatesAutoresizingMaskIntoConstraints = false
      stack.orientation = .horizontal
      stack.alignment = .centerY
      stack.spacing = 8
    }
    oscFloatingBottomView.translatesAutoresizingMaskIntoConstraints = false
    controlBarFloating.addSubview(oscFloatingTopView)
    controlBarFloating.addSubview(oscFloatingBottomView)
    controlBarBottom.addSubview(oscBottomMainView)
    titleBarView.addSubview(oscTopMainView)
    titleBarHeightConstraint = titleBarView.heightAnchor.constraint(equalToConstant: TitleBarHeightNormal)
    oscTopMainViewTopConstraint = oscTopMainView.topAnchor.constraint(equalTo: titleBarView.topAnchor)
    sideBarRightConstraint = content.trailingAnchor.constraint(equalTo: sideBarView.trailingAnchor, constant: 0)
    sideBarWidthConstraint = sideBarView.widthAnchor.constraint(equalToConstant: 240)
    let floatingWidth = controlBarFloating.widthAnchor.constraint(equalToConstant: 560)
    floatingWidth.priority = .defaultHigh
    NSLayoutConstraint.activate([
      videoView.leadingAnchor.constraint(equalTo: content.leadingAnchor), videoView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      videoView.topAnchor.constraint(equalTo: content.topAnchor), videoView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      titleBarView.leadingAnchor.constraint(equalTo: content.leadingAnchor), titleBarView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      titleBarView.topAnchor.constraint(equalTo: content.topAnchor), titleBarHeightConstraint,
      controlBarBottom.leadingAnchor.constraint(equalTo: content.leadingAnchor), controlBarBottom.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      controlBarBottom.bottomAnchor.constraint(equalTo: content.bottomAnchor), controlBarBottom.heightAnchor.constraint(equalToConstant: 40),
      sideBarView.topAnchor.constraint(equalTo: content.topAnchor), content.bottomAnchor.constraint(equalTo: sideBarView.bottomAnchor),
      sideBarRightConstraint, sideBarWidthConstraint,
      controlBarFloating.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      controlBarFloating.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
      controlBarFloating.heightAnchor.constraint(equalToConstant: 76), floatingWidth,
      oscTopMainView.leadingAnchor.constraint(equalTo: titleBarView.leadingAnchor, constant: 8),
      oscTopMainView.trailingAnchor.constraint(equalTo: titleBarView.trailingAnchor, constant: -8),
      oscTopMainViewTopConstraint, oscTopMainView.heightAnchor.constraint(equalToConstant: 24),
      oscFloatingTopView.leadingAnchor.constraint(equalTo: controlBarFloating.leadingAnchor, constant: 8),
      oscFloatingTopView.trailingAnchor.constraint(equalTo: controlBarFloating.trailingAnchor, constant: -8),
      oscFloatingTopView.topAnchor.constraint(equalTo: controlBarFloating.topAnchor, constant: 8),
      oscFloatingTopView.heightAnchor.constraint(equalToConstant: 24),
      oscFloatingBottomView.leadingAnchor.constraint(equalTo: controlBarFloating.leadingAnchor, constant: 8),
      oscFloatingBottomView.trailingAnchor.constraint(equalTo: controlBarFloating.trailingAnchor, constant: -8),
      oscFloatingBottomView.bottomAnchor.constraint(equalTo: controlBarFloating.bottomAnchor, constant: -8),
      oscFloatingBottomView.heightAnchor.constraint(equalToConstant: 22),
      oscBottomMainView.leadingAnchor.constraint(equalTo: controlBarBottom.leadingAnchor),
      oscBottomMainView.trailingAnchor.constraint(equalTo: controlBarBottom.trailingAnchor),
      oscBottomMainView.centerYAnchor.constraint(equalTo: controlBarBottom.centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("Use init(fixture:)") }
  func showUI(force: Bool) { shown += 1; currentControlBar?.isHidden = false }
  func updateTimer() { timerUpdates += 1 }
  func addBackTitlebarViewToFadeableViews() { fadeableViews.append(titleBarView) }
  func removeTitlebarViewFromFadeableViews() { fadeableViews.removeAll { $0 === titleBarView } }
  @objc func toolBarButtonAction(_ sender: NSButton) {}
  @objc func showEdgeMediaInformation(_ sender: NSButton) {}
}

final class PlaylistLayoutController: NSViewController, NSTableViewDataSource {
  let sortControls = PlaylistSortControls()
  let tagFilterControls = PlaylistTagFilterControls()
  let filterEmptyLabel = NSTextField(wrappingLabelWithString: playlistBrowserString("filter.empty"))
  var playlistTableView: NSTableView!
  var tabHeightConstraint: NSLayoutConstraint!
  var buttonTopConstraint: NSLayoutConstraint!
  // PRODUCTION_PLAYLIST_SHIFT_PROPERTY
  // PRODUCTION_PLAYLIST_COMPACT_PROPERTY

  init(fixture: ChromeFixture) throws {
    super.init(nibName: nil, bundle: nil)
    view = try fixture.fragment("Hz6-mo-xeY")
    playlistTableView = (fixture.view("n5h-uy-hbd") as! NSScrollView).documentView as? NSTableView
    playlistTableView.dataSource = self
    tabHeightConstraint = try fixture.constraint(forOutlet: "tabHeightConstraint")
    buttonTopConstraint = try fixture.constraint(forOutlet: "buttonTopConstraint")
    installSortControls()
    applyProductionTableMetrics()
    playlistTableView.reloadData()
  }

  required init?(coder: NSCoder) { fatalError("Use init(fixture:)") }
  func requestSort(key: PlaylistFileSortKey, ascending: Bool) {}
  func refreshFileMetadata(force: Bool) {}
  func requestTagFilter(_ filter: PlaylistTagFilter) {}
  func numberOfRows(in tableView: NSTableView) -> Int { 20 }
  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
    "Sample Video \(row + 1).mp4"
  }
}
