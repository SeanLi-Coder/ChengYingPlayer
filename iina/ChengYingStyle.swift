import Cocoa

/// Shared native styling. Colors follow the window appearance, never the video surface.
enum ChengYingStyle {
  static let accent = color("Accent", light: (0.03, 0.38, 0.58), dark: (0.39, 0.82, 0.94))
  static let surface = color("Surface", light: (0.96, 0.97, 0.99), dark: (0.075, 0.09, 0.12))
  static let card = color("Card", light: (1, 1, 1), dark: (0.12, 0.14, 0.18))
  static let border = NSColor(name: "ChengYing.Border") { appearance in
    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let alpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.55 : 0.13
    return (dark ? NSColor.white : NSColor.black).withAlphaComponent(alpha)
  }

  private static func color(_ name: String, light: (CGFloat, CGFloat, CGFloat),
                            dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
    NSColor(name: "ChengYing.\(name)") { appearance in
      let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
      return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
    }
  }

  static func primaryButton(_ button: NSButton) {
    if !(button.cell is ChengYingPrimaryButtonCell) {
      let title = button.title
      let image = button.image
      let imagePosition = button.imagePosition
      let imageScaling = button.imageScaling
      let target = button.target
      let action = button.action
      let keyEquivalent = button.keyEquivalent
      let modifiers = button.keyEquivalentModifierMask
      let enabled = button.isEnabled
      let refusesFirstResponder = button.refusesFirstResponder
      button.cell = ChengYingPrimaryButtonCell(textCell: title)
      button.setButtonType(.momentaryPushIn)
      button.title = title
      button.image = image
      button.imagePosition = imagePosition
      button.imageScaling = imageScaling
      button.target = target
      button.action = action
      button.keyEquivalent = keyEquivalent
      button.keyEquivalentModifierMask = modifiers
      button.isEnabled = enabled
      button.refusesFirstResponder = refusesFirstResponder
    }
    secondaryButton(button)
    button.font = .systemFont(ofSize: 13, weight: .semibold)
    button.bezelColor = NSColor(srgbRed: 0.04, green: 0.40, blue: 0.63, alpha: 1)
    button.contentTintColor = .white
  }

  static func secondaryButton(_ button: NSButton) {
    button.bezelStyle = .rounded
    button.font = .systemFont(ofSize: 12, weight: .medium)
    button.contentTintColor = .labelColor
    if #available(macOS 11.0, *) { button.controlSize = .large }
    button.setContentCompressionResistancePriority(.required, for: .vertical)
  }

  static func segmented(_ control: NSSegmentedControl) {
    control.segmentStyle = .rounded
    control.segmentDistribution = .fillEqually
    control.font = .systemFont(ofSize: 12, weight: .medium)
    if #available(macOS 11.0, *) { control.controlSize = .large }
  }

  static func tabButton(_ button: NSButton, selected: Bool) {
    if !(button.cell is ChengYingTabButtonCell) {
      let title = button.title
      let target = button.target
      let action = button.action
      let tag = button.tag
      let enabled = button.isEnabled
      let keyEquivalent = button.keyEquivalent
      let modifiers = button.keyEquivalentModifierMask
      let refusesFirstResponder = button.refusesFirstResponder
      button.cell = ChengYingTabButtonCell(textCell: title)
      button.setButtonType(.momentaryPushIn)
      button.title = title
      button.target = target
      button.action = action
      button.tag = tag
      button.isEnabled = enabled
      button.keyEquivalent = keyEquivalent
      button.keyEquivalentModifierMask = modifiers
      button.refusesFirstResponder = refusesFirstResponder
      button.imagePosition = .noImage
      button.isBordered = true
      button.bezelStyle = .regularSquare
      button.focusRingType = .exterior
      button.font = .systemFont(ofSize: 12, weight: .medium)
    }
    (button.cell as? ChengYingTabButtonCell)?.isSelectedTab = selected
    button.setAccessibilityValue(selected ? 1 : 0)
    button.needsDisplay = true
  }

  static func textField(_ field: NSTextField) {
    field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    field.focusRingType = .default
    field.bezelStyle = .roundedBezel
    field.textColor = .labelColor
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }

  static func symbol(_ name: String, fallback: NSImage.Name = NSImage.actionTemplateName) -> NSImage {
    if #available(macOS 11.0, *), let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
      return image
    }
    return NSImage(named: fallback) ?? NSImage(size: NSSize(width: 16, height: 16))
  }

  static func heading(_ title: String, subtitle: String? = nil) -> NSView {
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 20, weight: .semibold)
    label.textColor = .labelColor
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    let stack = NSStackView(views: [label])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 5
    if let subtitle {
      let detail = NSTextField(wrappingLabelWithString: subtitle)
      detail.font = .systemFont(ofSize: 12)
      detail.textColor = .secondaryLabelColor
      stack.addArrangedSubview(detail)
    }
    for child in stack.arrangedSubviews {
      child.translatesAutoresizingMaskIntoConstraints = false
      child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    return stack
  }

  static func card(_ content: NSView,
                   insets: NSEdgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)) -> NSView {
    let container = ChengYingCardView()
    container.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
      content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
      content.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
      content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom),
    ])
    return container
  }
}

/// Preserve native keyboard/accessibility behavior while keeping the primary action distinct.
final class ChengYingPrimaryButtonCell: NSButtonCell {
  override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
    let path = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
    let base = NSColor(srgbRed: 0.04, green: 0.40, blue: 0.63, alpha: 1)
    let fill = !isEnabled ? NSColor.quaternaryLabelColor :
      (isHighlighted ? base.blended(withFraction: 0.18, of: .black)! : base)
    fill.setFill()
    path.fill()
    if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
      NSColor.labelColor.setStroke()
      path.lineWidth = 1
      path.stroke()
    }
  }

  override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect,
                          in controlView: NSView) -> NSRect {
    let styled = NSMutableAttributedString(attributedString: title)
    styled.addAttribute(.foregroundColor, value: isEnabled ? NSColor.white : .disabledControlTextColor,
                        range: NSRange(location: 0, length: styled.length))
    return super.drawTitle(styled, withFrame: frame, in: controlView)
  }

  override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
    let color = isEnabled ? NSColor.white : .disabledControlTextColor
    let tinted = NSImage(size: image.size, flipped: false) { rect in
      image.draw(in: rect)
      color.setFill()
      rect.fill(using: .sourceIn)
      return true
    }
    super.drawImage(tinted, withFrame: frame, in: controlView)
  }
}

/// A compact native tab whose selected state remains visible without a hover animation.
final class ChengYingTabButtonCell: NSButtonCell {
  var isSelectedTab = false

  override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
    guard isSelectedTab || isHighlighted else { return }
    let path = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 5), xRadius: 9, yRadius: 9)
    ChengYingStyle.accent.withAlphaComponent(isSelectedTab ? 0.16 : 0.08).setFill()
    path.fill()
    if isSelectedTab {
      ChengYingStyle.accent.withAlphaComponent(0.45).setStroke()
      path.lineWidth = 1
      path.stroke()
    }
  }

  override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect,
                          in controlView: NSView) -> NSRect {
    let styled = NSMutableAttributedString(attributedString: title)
    styled.addAttribute(.foregroundColor,
                        value: isSelectedTab ? ChengYingStyle.accent : NSColor.secondaryLabelColor,
                        range: NSRange(location: 0, length: styled.length))
    return super.drawTitle(styled, withFrame: frame, in: controlView)
  }
}

/// Opaque card fills remain legible when Reduce Transparency is enabled.
final class ChengYingCardView: NSView {
  private var accessibilityObserver: NSObjectProtocol?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil, queue: .main
    ) { [weak self] _ in self?.needsDisplay = true }
  }

  required init?(coder: NSCoder) { super.init(coder: coder) }

  deinit {
    if let accessibilityObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
    ChengYingStyle.card.setFill()
    path.fill()
    ChengYingStyle.border.setStroke()
    path.lineWidth = 1
    path.stroke()
  }
}
