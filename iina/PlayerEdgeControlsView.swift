import Cocoa

/// Video controls remain dark independently of the appearance of the surrounding app.
struct PlayerControlsAccessibility {
  let reduceTransparency: Bool
  let increaseContrast: Bool

  static var current: PlayerControlsAccessibility {
    PlayerControlsAccessibility(
      reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
      increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
  }
}

/// Reuses the existing controls so seeking, tracking, shortcuts, and bindings stay intact.
final class PlayerEdgeControlsView: NSView {
  static let preferredHeight: CGFloat = 62

  let timeline: NSView
  let transport: NSView
  let volume: NSView

  private let accessibility: () -> PlayerControlsAccessibility
  private var accessibilityObserver: NSObjectProtocol?

  init(timeline: NSView, transport: NSView, volume: NSView,
       accessibility: @escaping () -> PlayerControlsAccessibility = { .current }) {
    self.timeline = timeline
    self.transport = transport
    self.volume = volume
    self.accessibility = accessibility
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    appearance = NSAppearance(named: .darkAqua)
    userInterfaceLayoutDirection = .leftToRight
    for fragment in [timeline, transport, volume] {
      if let stack = fragment.superview as? NSStackView { stack.removeView(fragment) }
      fragment.removeFromSuperview()
      fragment.translatesAutoresizingMaskIntoConstraints = false
      addSubview(fragment)
    }
    for fragment in [transport, volume] {
      fragment.setContentHuggingPriority(.required, for: .horizontal)
      fragment.setContentHuggingPriority(.required, for: .vertical)
    }
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.preferredHeight),
      timeline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      timeline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      timeline.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
      timeline.heightAnchor.constraint(equalToConstant: 22),
      transport.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      transport.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -43),
      transport.heightAnchor.constraint(lessThanOrEqualToConstant: 28),
      volume.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      volume.centerYAnchor.constraint(equalTo: transport.centerYAnchor),
      volume.heightAnchor.constraint(lessThanOrEqualToConstant: 28),
      volume.leadingAnchor.constraint(greaterThanOrEqualTo: transport.trailingAnchor, constant: 12),
    ])
    accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil, queue: .main
    ) { [weak self] _ in self?.needsDisplay = true }
  }

  required init?(coder: NSCoder) { fatalError("Use init(timeline:transport:volume:)") }

  deinit {
    if let accessibilityObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
    }
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight)
  }

  override func draw(_ dirtyRect: NSRect) {
    let options = accessibility()
    if options.reduceTransparency {
      NSColor(srgbRed: 0.055, green: 0.065, blue: 0.08, alpha: 1).setFill()
      bounds.fill()
    } else {
      let opacity: CGFloat = options.increaseContrast ? 0.90 : 0.72
      NSGradient(colorsAndLocations:
        (NSColor.black.withAlphaComponent(opacity), 0),
        (NSColor.black.withAlphaComponent(opacity * 0.56), 0.53),
        (.clear, 1))?.draw(in: bounds, angle: 90)
    }
    if options.increaseContrast {
      NSColor.white.withAlphaComponent(0.72).setFill()
      NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1).fill()
    }
  }

  /// Empty video space between the compact controls keeps the player's mouse actions.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0.001 else { return nil }
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

/// A small upper-corner strip, not a floating playback panel.
final class PlayerCornerControlsView: NSVisualEffectView {
  let toolbar: NSView

  private let accessibility: () -> PlayerControlsAccessibility
  private var accessibilityObserver: NSObjectProtocol?
  private let opaqueBackground = NSView(frame: .zero)

  init(toolbar: NSView,
       accessibility: @escaping () -> PlayerControlsAccessibility = { .current }) {
    self.toolbar = toolbar
    self.accessibility = accessibility
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    appearance = NSAppearance(named: .darkAqua)
    userInterfaceLayoutDirection = .leftToRight
    material = .hudWindow
    blendingMode = .withinWindow
    state = .active
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.masksToBounds = true
    // A child layer sits above the visual effect; drawing the effect view itself does not.
    opaqueBackground.translatesAutoresizingMaskIntoConstraints = false
    opaqueBackground.wantsLayer = true
    opaqueBackground.layer?.backgroundColor = NSColor(srgbRed: 0.055, green: 0.065, blue: 0.08, alpha: 1).cgColor
    addSubview(opaqueBackground)
    if let stack = toolbar.superview as? NSStackView { stack.removeView(toolbar) }
    toolbar.removeFromSuperview()
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    toolbar.setContentHuggingPriority(.required, for: .horizontal)
    toolbar.setContentHuggingPriority(.required, for: .vertical)
    addSubview(toolbar)
    NSLayoutConstraint.activate([
      opaqueBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
      opaqueBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
      opaqueBackground.topAnchor.constraint(equalTo: topAnchor),
      opaqueBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
      toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      toolbar.centerYAnchor.constraint(equalTo: centerYAnchor),
      toolbar.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
      toolbar.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
      heightAnchor.constraint(equalToConstant: 36),
    ])
    accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil, queue: .main
    ) { [weak self] _ in self?.refreshAccessibility() }
    refreshAccessibility()
  }

  required init?(coder: NSCoder) { fatalError("Use init(toolbar:)") }

  deinit {
    if let accessibilityObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
    }
  }

  private func refreshAccessibility() {
    let options = accessibility()
    opaqueBackground.isHidden = !options.reduceTransparency
    layer?.borderWidth = options.increaseContrast ? 1 : 0
    layer?.borderColor = NSColor.white.withAlphaComponent(0.72).cgColor
    needsDisplay = true
  }

}
