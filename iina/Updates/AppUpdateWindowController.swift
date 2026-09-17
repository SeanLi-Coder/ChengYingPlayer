import AppKit

struct AppUpdatePresentation {
  var title: String
  var detail: String
  var progress: Double?
  var isWorking: Bool = true
  var primaryTitle: String? = nil
  var secondaryTitle: String? = nil
}

private final class AppUpdateWindow: NSWindow {
  // Keep media commands routed to the active player while update controls accept focus.
  override var canBecomeMain: Bool { false }
  override var canBecomeKey: Bool { true }
}

private final class AppUpdateBackgroundView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
  }
}

private final class AppUpdateProgressIndicator: NSProgressIndicator {
  override func draw(_ dirtyRect: NSRect) {
    guard !isIndeterminate else { super.draw(dirtyRect); return }
    // Keep determinate progress visible in inactive windows and accessibility snapshots.
    let track = NSRect(x: bounds.minX, y: bounds.midY - 3, width: bounds.width, height: 6)
    NSColor.quaternaryLabelColor.setFill()
    NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
    let fraction = maxValue > minValue ? min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))) : 0
    guard fraction > 0 else { return }
    let fill = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
    NSColor.controlAccentColor.setFill()
    NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
  }
}

/// Closing this window only hides it; cancellation is always an explicit action.
@MainActor
final class AppUpdateWindowController: NSWindowController, NSWindowDelegate {
  private let heading = NSTextField(labelWithString: "")
  private let detail = NSTextField(wrappingLabelWithString: "")
  private let progress = AppUpdateProgressIndicator()
  private let primary = NSButton(title: "", target: nil, action: nil)
  private let secondary = NSButton(title: "", target: nil, action: nil)
  private let automaticToggle = NSButton(checkboxWithTitle: AppUpdateText.string("preference.automatic"),
                                         target: nil, action: nil)
  private let footnote = NSTextField(wrappingLabelWithString: AppUpdateText.string("window.close_hint"))
  var onPrimary: (() -> Void)?
  var onSecondary: (() -> Void)?
  var onAutomaticChecksChanged: ((Bool) -> Void)?
  private(set) var presentation: AppUpdatePresentation?

  init() {
    let window = AppUpdateWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 285),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = AppUpdateText.string("window.title")
    window.isReleasedWhenClosed = false
    window.contentView = AppUpdateBackgroundView(frame: NSRect(x: 0, y: 0, width: 460, height: 285))
    super.init(window: window)
    window.delegate = self
    window.center()
    guard let content = window.contentView else { return }
    heading.font = .systemFont(ofSize: 19, weight: .semibold)
    heading.maximumNumberOfLines = 2
    detail.font = .systemFont(ofSize: 13)
    detail.textColor = .secondaryLabelColor
    detail.maximumNumberOfLines = 5
    detail.isSelectable = true
    detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    footnote.font = .systemFont(ofSize: 11)
    footnote.textColor = .tertiaryLabelColor
    progress.style = .bar
    progress.minValue = 0
    progress.maxValue = 1
    primary.bezelStyle = .rounded
    secondary.bezelStyle = .rounded
    primary.target = self
    primary.action = #selector(performPrimary)
    secondary.target = self
    secondary.action = #selector(performSecondary)
    automaticToggle.target = self
    automaticToggle.action = #selector(automaticChecksChanged)
    let buttons = NSStackView(views: [secondary, primary])
    buttons.orientation = .horizontal
    buttons.spacing = 8
    for view in [heading, detail, progress, automaticToggle, footnote, buttons] {
      view.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(view)
    }
    NSLayoutConstraint.activate([
      heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
      heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
      heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
      detail.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
      detail.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
      detail.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
      progress.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
      progress.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
      progress.topAnchor.constraint(greaterThanOrEqualTo: detail.bottomAnchor, constant: 12),
      progress.bottomAnchor.constraint(equalTo: automaticToggle.topAnchor, constant: -12),
      automaticToggle.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
      automaticToggle.trailingAnchor.constraint(lessThanOrEqualTo: heading.trailingAnchor),
      automaticToggle.bottomAnchor.constraint(equalTo: footnote.topAnchor, constant: -10),
      footnote.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
      footnote.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
      footnote.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),
      buttons.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
      buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
    ])
  }

  required init?(coder: NSCoder) { nil }

  func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    automaticToggle.state = enabled ? .on : .off
  }

  func render(_ state: AppUpdatePresentation) {
    presentation = state
    heading.stringValue = state.title
    detail.stringValue = state.detail
    progress.isIndeterminate = state.progress == nil
    if let fraction = state.progress { progress.doubleValue = min(1, max(0, fraction)) }
    progress.isHidden = !state.isWorking
    if state.isWorking && state.progress == nil { progress.startAnimation(nil) }
    else { progress.stopAnimation(nil) }
    progress.needsDisplay = true
    primary.title = state.primaryTitle ?? ""
    primary.isHidden = state.primaryTitle == nil
    secondary.title = state.secondaryTitle ?? ""
    secondary.isHidden = state.secondaryTitle == nil
    footnote.isHidden = !state.isWorking
    window?.contentView?.layoutSubtreeIfNeeded()
  }

  func present(activate: Bool) {
    if activate {
      NSApp.activate(ignoringOtherApps: true)
      showWindow(nil)
      window?.makeKeyAndOrderFront(nil)
    } else {
      window?.orderFront(nil)
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    return false
  }

  @objc private func performPrimary() { onPrimary?() }
  @objc private func performSecondary() { onSecondary?() }
  @objc private func automaticChecksChanged() { onAutomaticChecksChanged?(automaticToggle.state == .on) }
}
