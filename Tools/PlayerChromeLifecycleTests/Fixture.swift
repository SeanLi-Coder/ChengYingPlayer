import Cocoa
import QuartzCore

let UIAnimationDuration = 0.25
let SideBarAnimationDuration = 0.2
let SettingsWidth: CGFloat = 360
let PlaylistMinWidth: CGFloat = 240
let PlaylistMaxWidth: CGFloat = 500

extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
extension NSView {
  func chromeImmediateAnimator() -> NSView { self }
}
extension NSLayoutConstraint {
  func chromeImmediateAnimator() -> NSLayoutConstraint { self }
}

enum ChromeInput {
  static var pressedMouseButtons = 0
  static var cursorHides: [Bool] = []
  static func setHiddenUntilMouseMoves(_ hidden: Bool) { cursorHides.append(hidden) }
}
enum ChromeDefaults {
  static let suite = "ChengYingPlayer.ChromeLifecycleTests.\(UUID().uuidString)"
  static let value = UserDefaults(suiteName: suite)!
}
enum Preference {
  enum Key { case enableControlBarAutoHide, controlBarAutoHideTimeout, disableAnimations, playlistWidth }
  enum OSCPosition { case floating, top, bottom }
  static var autoHide = true
  static var timeout: Float = 2.5
  static var disableAnimations = false
  static func bool(for key: Key) -> Bool {
    switch key {
    case .enableControlBarAutoHide: return autoHide
    case .disableAnimations: return disableAnimations
    default: fatalError("Unexpected Boolean preference")
    }
  }
  static func float(for key: Key) -> Float { timeout }
  static func integer(for key: Key) -> Int { 320 }
}
typealias PK = Preference.Key
enum Logger {
  static func fatal(_ message: String) -> Never { fatalError(message) }
}
enum AccessibilityPreferences {
  static var motionReductionEnabled = false
  static func adjustedDuration(_ value: TimeInterval) -> TimeInterval { Preference.disableAnimations ? 0 : value }
}

final class ChromeAnimations {
  final class Context {
    var duration: TimeInterval = 0
    var timingFunction: CAMediaTimingFunction?
  }
  struct Pending {
    let duration: TimeInterval
    let completion: (() -> Void)?
  }
  static var pending: [Pending?] = []
  static func runAnimationGroup(_ changes: (Context) -> Void, completionHandler: (() -> Void)? = nil) {
    let context = Context()
    changes(context)
    pending.append(Pending(duration: context.duration, completion: completionHandler))
  }
  static func complete(_ index: Int) {
    guard pending.indices.contains(index), let item = pending[index] else {
      fatalError("Animation completion was absent or already consumed: \(index)")
    }
    pending[index] = nil
    item.completion?()
  }
  static func drain() {
    var index = 0
    while index < pending.count {
      if pending[index] != nil { complete(index) }
      index += 1
    }
  }
  static func reset() { pending.removeAll() }
}

final class ChromeWindow: NSWindow {
  var testVisible = true
  var testPointer = NSPoint(x: 350, y: 250)
  var testSheet: NSWindow?
  var testResponder: NSResponder?
  var cursorResets = 0
  override var isVisible: Bool { testVisible }
  override var mouseLocationOutsideOfEventStream: NSPoint { testPointer }
  override var attachedSheet: NSWindow? { testSheet }
  override var firstResponder: NSResponder? { testResponder ?? super.firstResponder }
  override func resetCursorRects() { cursorResets += 1 }
}

final class ChromeEvents {
  enum Event { case windowWillClose }
  var closed = 0
  func emit(_ event: Event) { closed += 1 }
}
final class ChromePlayer {
  final class Info { var state = PlayerState.playing }
  let info = Info()
  var disableUI = false
  var refreshes = 0
  var stops = 0
  let events = ChromeEvents()
  func refreshSyncUITimer() { refreshes += 1 }
  func stop() { stops += 1 }
}
final class FloatingControls: NSView { var isDragging = false }
final class PlayerCornerControlsView: NSView {}
final class ChromeTextField: NSTextField, NSTextViewDelegate {}

class FixtureSidebar: NSViewController, SidebarViewController {
  var downShift: CGFloat = -1
  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
    view.translatesAutoresizingMaskIntoConstraints = false
  }
}
final class QuickSettingViewController: FixtureSidebar {
  enum TabViewType { case video, audio, sub }
  var currentTab: TabViewType = .video
  func pleaseSwitchToTab(_ tab: TabViewType) { currentTab = tab }
}
final class PlaylistViewController: FixtureSidebar {
  enum TabViewType { case playlist, chapters }
  var currentTab: TabViewType = .playlist
  var useCompactTabHeight = false
  func pleaseSwitchToTab(_ tab: TabViewType) { currentTab = tab }
}

class ChromeFixture: NSResponder {
  enum FullScreenState {
    case windowed
    case fullscreen(legacy: Bool, priorWindowedFrame: NSRect)
    var isFullscreen: Bool {
      if case .fullscreen = self { return true }
      return false
    }
  }
  let player = ChromePlayer()
  var window: ChromeWindow?
  var oscPosition = Preference.OSCPosition.bottom
  var fadeableViews: [NSView] = []
  let standardWindowButtons = [NSButton(), NSButton(), NSButton()]
  let fragSliderView = NSView(frame: NSRect(x: 0, y: 0, width: 650, height: 25))
  let fragControlView = NSView(frame: NSRect(x: 260, y: 25, width: 140, height: 35))
  let fragVolumeView = NSView(frame: NSRect(x: 490, y: 25, width: 160, height: 35))
  let fragToolbarView = NSView(frame: NSRect(x: 0, y: 60, width: 160, height: 35))
  let titleBarView = NSView(frame: NSRect(x: 0, y: 450, width: 650, height: 30))
  let sideBarView = NSView(frame: NSRect(x: 420, y: 210, width: 220, height: 220))
  let subPopoverView = NSView(frame: .zero)
  var cornerControls: PlayerCornerControlsView? = PlayerCornerControlsView(frame: NSRect(x: 540, y: 420, width: 110, height: 25))
  let controlBarFloating = FloatingControls()
  let playSlider = NSSlider()
  let timePreviewWhenSeek = NSView()
  let thumbnailPeekView = NSView()
  var titleTextField: NSTextField? = NSTextField(labelWithString: "Fixture")
  let sideBarWidthConstraint = NSLayoutConstraint()
  let sideBarRightConstraint = NSLayoutConstraint()
  let titleBarHeightConstraint = NSLayoutConstraint()
  let quickSettingView = QuickSettingViewController()
  let playlistView = PlaylistViewController()
  var sidebarMaxWidth: CGFloat { max(window!.frame.width * 0.8, PlaylistMinWidth) }
  var hideControlTimer: Timer?
  var isResizingSidebar = false
  var isInInteractiveMode = false
  var isMouseInWindow = true
  var shouldApplyInitialWindowSize = false
  var pipStatus = MainWindowUnderTest.PIPStatus.notInPIP
  var fsState = FullScreenState.windowed
  var pipExits = 0
  var dockRestores = 0
  var seekPreviewRefreshes = 0

  override init() {
    super.init()
    let fixture = ChromeWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 480),
                               styleMask: [.borderless], backing: .buffered, defer: false)
    fixture.isReleasedWhenClosed = false
    window = fixture
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 650, height: 480))
    fixture.contentView = root
    let views = [fragSliderView, fragControlView, fragVolumeView, fragToolbarView, titleBarView, sideBarView,
                 subPopoverView, cornerControls!, playSlider, timePreviewWhenSeek, thumbnailPeekView]
    views.forEach { root.addSubview($0) }
    standardWindowButtons.forEach { titleBarView.addSubview($0) }
    titleBarView.addSubview(titleTextField!)
    sideBarView.isHidden = true
    titleBarHeightConstraint.constant = 30
    fadeableViews = [fragSliderView, fragControlView, fragVolumeView, titleBarView, cornerControls!] + standardWindowButtons
  }
  required init?(coder: NSCoder) { fatalError("Not used") }
  func exitPIP() { pipExits += 1 }
  func restoreDockSettings() { dockRestores += 1 }
  func refreshSeekTimeAndThumbnail(from event: NSEvent) { seekPreviewRefreshes += 1 }
  func isMouseEvent(_ event: NSEvent, inAnyOf views: [NSView?]) -> Bool {
    views.contains { PlayerChromePolicy.contains(event.locationInWindow, in: $0, window: window) }
  }
}
