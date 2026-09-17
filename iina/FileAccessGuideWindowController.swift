import Cocoa

func fileAccessString(_ key: String) -> String {
  NSLocalizedString(key, tableName: "FileAccess", comment: "Optional file access guide")
}

private final class FileAccessGuideWindow: NSWindow {
  // Opening this guide must not replace the active player as the main window.
  override var canBecomeMain: Bool { false }
  override var canBecomeKey: Bool { true }
}

private final class FileAccessGuideBackgroundView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    ChengYingStyle.surface.setFill()
    dirtyRect.fill()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

/// Explains a user-controlled macOS setting without probing or changing permissions.
final class FileAccessGuideWindowController: NSWindowController, NSWindowDelegate {
  let settingsButton = NSButton()
  let revealButton = NSButton()
  let continueButton = NSButton()
  let statusLabel = NSTextField(wrappingLabelWithString: "")
  var onClose: (() -> Void)?

  private let openSettings: () -> Bool
  private let revealApplication: () -> Void
  private let body = NSView()
  private var statusHeight: NSLayoutConstraint!
  private var statusSpacing: NSLayoutConstraint!
  private let contentWidth: CGFloat = 560
  private let padding: CGFloat = 24

  init(openSettings: @escaping () -> Bool, revealApplication: @escaping () -> Void) {
    self.openSettings = openSettings
    self.revealApplication = revealApplication
    let window = FileAccessGuideWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = fileAccessString("menu.title")
    window.isReleasedWhenClosed = false
    window.contentView = FileAccessGuideBackgroundView(frame: window.contentView!.bounds)
    super.init(window: window)
    window.delegate = self
    buildContent()
    fitWindow()
    window.center()
  }

  required init?(coder: NSCoder) { nil }

  func present() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    onClose?()
  }

  private func label(_ key: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                     color: NSColor = .secondaryLabelColor, width: CGFloat? = nil) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: fileAccessString(key))
    field.identifier = NSUserInterfaceItemIdentifier("fileAccess.\(key)")
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.maximumNumberOfLines = 0
    field.preferredMaxLayoutWidth = width ?? contentWidth - padding * 2
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setContentCompressionResistancePriority(.required, for: .vertical)
    field.setContentHuggingPriority(.required, for: .vertical)
    field.isSelectable = true
    return field
  }

  private func buildContent() {
    guard let content = window?.contentView else { return }
    body.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(body)
    NSLayoutConstraint.activate([
      body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding),
      body.topAnchor.constraint(equalTo: content.topAnchor, constant: padding),
      body.widthAnchor.constraint(equalToConstant: contentWidth - padding * 2)
    ])

    let header = NSView()
    header.translatesAutoresizingMaskIntoConstraints = false
    let icon = NSImageView(image: ChengYingStyle.symbol("lock.shield"))
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.contentTintColor = ChengYingStyle.accent
    icon.setAccessibilityElement(false)
    let heading = label("menu.title", size: 21, weight: .semibold, color: .labelColor,
                        width: contentWidth - padding * 2 - 44)
    header.addSubview(icon)
    header.addSubview(heading)
    NSLayoutConstraint.activate([
      header.heightAnchor.constraint(equalToConstant: 34),
      icon.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      icon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 30),
      icon.heightAnchor.constraint(equalToConstant: 30),
      heading.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
      heading.trailingAnchor.constraint(equalTo: header.trailingAnchor),
      heading.centerYAnchor.constraint(equalTo: header.centerYAnchor)
    ])

    let introduction = label("intro")
    let steps = makeSteps()
    let limitations = label("limitations", size: 11)
    let footer = label("footer", size: 10)

    configureButton(settingsButton, key: "button.settings", action: #selector(openSystemSettings), primary: true)
    configureButton(revealButton, key: "button.reveal", action: #selector(revealInstalledApplication))
    configureButton(continueButton, key: "button.continue", action: #selector(continueUsingApplication))
    continueButton.keyEquivalent = "\u{1b}"
    continueButton.keyEquivalentModifierMask = []
    let secondaryActions = NSView()
    secondaryActions.translatesAutoresizingMaskIntoConstraints = false
    secondaryActions.addSubview(revealButton)
    secondaryActions.addSubview(continueButton)
    NSLayoutConstraint.activate([
      secondaryActions.heightAnchor.constraint(equalToConstant: 34),
      revealButton.leadingAnchor.constraint(equalTo: secondaryActions.leadingAnchor),
      revealButton.topAnchor.constraint(equalTo: secondaryActions.topAnchor),
      revealButton.bottomAnchor.constraint(equalTo: secondaryActions.bottomAnchor),
      continueButton.leadingAnchor.constraint(equalTo: revealButton.trailingAnchor, constant: 10),
      continueButton.trailingAnchor.constraint(equalTo: secondaryActions.trailingAnchor),
      continueButton.topAnchor.constraint(equalTo: secondaryActions.topAnchor),
      continueButton.bottomAnchor.constraint(equalTo: secondaryActions.bottomAnchor),
      continueButton.widthAnchor.constraint(equalTo: revealButton.widthAnchor)
    ])

    statusLabel.identifier = NSUserInterfaceItemIdentifier("fileAccess.status")
    statusLabel.font = .systemFont(ofSize: 12)
    statusLabel.textColor = .systemRed
    statusLabel.maximumNumberOfLines = 0
    statusLabel.preferredMaxLayoutWidth = contentWidth - padding * 2
    statusLabel.isSelectable = true
    statusLabel.isHidden = true
    statusLabel.translatesAutoresizingMaskIntoConstraints = false

    let sections: [(NSView, CGFloat)] = [
      (header, 0), (introduction, 12), (steps, 16), (limitations, 14),
      (statusLabel, 0), (settingsButton, 16), (secondaryActions, 8), (footer, 12)
    ]
    var previous: NSView?
    for (view, spacing) in sections {
      body.addSubview(view)
      NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: body.trailingAnchor)
      ])
      let top = view.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? body.topAnchor, constant: spacing)
      top.isActive = true
      if view === statusLabel { statusSpacing = top }
      previous = view
    }
    footer.bottomAnchor.constraint(equalTo: body.bottomAnchor).isActive = true
    settingsButton.heightAnchor.constraint(equalToConstant: 38).isActive = true
    statusHeight = statusLabel.heightAnchor.constraint(equalToConstant: 0)
    statusHeight.isActive = true
  }

  private func makeSteps() -> NSView {
    let steps = NSView()
    let textWidth = contentWidth - padding * 2 - 28
    var previous: NSView?
    for number in 1...3 {
      let title = label("step.\(number).title", size: 12, weight: .semibold,
                        color: .labelColor, width: textWidth)
      let detail = label("step.\(number).detail", width: textWidth)
      steps.addSubview(title)
      steps.addSubview(detail)
      NSLayoutConstraint.activate([
        title.leadingAnchor.constraint(equalTo: steps.leadingAnchor),
        title.trailingAnchor.constraint(equalTo: steps.trailingAnchor),
        title.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? steps.topAnchor,
                                   constant: previous == nil ? 0 : 14),
        detail.leadingAnchor.constraint(equalTo: steps.leadingAnchor),
        detail.trailingAnchor.constraint(equalTo: steps.trailingAnchor),
        detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4)
      ])
      previous = detail
    }
    previous?.bottomAnchor.constraint(equalTo: steps.bottomAnchor).isActive = true
    return ChengYingStyle.card(steps, insets: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
  }

  private func configureButton(_ button: NSButton, key: String, action: Selector, primary: Bool = false) {
    button.identifier = NSUserInterfaceItemIdentifier("fileAccess.\(key)")
    button.title = fileAccessString(key)
    button.target = self
    button.action = action
    button.translatesAutoresizingMaskIntoConstraints = false
    if primary { ChengYingStyle.primaryButton(button) }
    else { ChengYingStyle.secondaryButton(button) }
  }

  private func fitWindow() {
    guard let window else { return }
    window.contentView?.layoutSubtreeIfNeeded()
    let height = ceil(body.fittingSize.height + padding * 2)
    window.setContentSize(NSSize(width: contentWidth, height: height))
    window.contentView?.layoutSubtreeIfNeeded()
  }

  @objc private func openSystemSettings() {
    let opened = openSettings()
    statusLabel.stringValue = opened ? "" : fileAccessString("settings.failed")
    statusLabel.isHidden = opened
    statusSpacing.constant = opened ? 0 : 12
    statusHeight.constant = opened ? 0 : ceil(statusLabel.intrinsicContentSize.height)
    fitWindow()
    if !opened {
      NSAccessibility.post(element: statusLabel, notification: .announcementRequested,
                           userInfo: [.announcement: statusLabel.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
  }

  @objc private func revealInstalledApplication() { revealApplication() }
  @objc private func continueUsingApplication() { window?.performClose(nil) }
}
