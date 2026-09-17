import Cocoa

/// An independent read-only inspector. Readers never receive an AppKit object.
final class MediaInfoWindowController: NSWindowController, NSWindowDelegate {
  typealias Reader = (URL, MediaInfoKind, MediaInfoCancellation) throws -> MediaInfoSnapshot

  private let reader: Reader
  private let readQueue = DispatchQueue(label: "chengying.media-info.read", qos: .userInitiated)
  private var cancellation: MediaInfoCancellation?
  private var generation: UInt64 = 0
  private var sourceURL: URL?
  private var sourceKind: MediaInfoKind = .video

  private(set) var displayedSnapshot: MediaInfoSnapshot?
  private(set) var isLoading = false
  private(set) var errorMessage: String?

  let refreshButton = NSButton()
  let copyButton = NSButton()
  let closeButton = NSButton()
  let scrollView = NSScrollView()
  private let sectionsStack = NSStackView()
  private let fileLabel = NSTextField(labelWithString: "")
  private let kindImage = NSImageView()

  init(reader: @escaping Reader) {
    self.reader = reader
    let window = MediaInfoWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 660),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    window.title = mediaInfoText("window.title", "Media Information")
    window.contentMinSize = NSSize(width: 440, height: 360)
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenAuxiliary]
    super.init(window: window)
    window.delegate = self
    buildInterface(in: window)
    showEmptyState()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit { cancellation?.cancel() }

  func present(url: URL, kind: MediaInfoKind, relativeTo owner: NSWindow?) {
    precondition(Thread.isMainThread)
    guard let window else { return }
    window.appearance = owner?.appearance
    if !window.isVisible {
      if let owner {
        let visible = owner.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? owner.frame
        let size = window.frame.size
        let origin = NSPoint(
          x: max(visible.minX, min(owner.frame.midX - size.width / 2, visible.maxX - size.width)),
          y: max(visible.minY, min(owner.frame.midY - size.height / 2, visible.maxY - size.height)))
        window.setFrameOrigin(origin)
      } else {
        window.center()
      }
    }
    window.makeKeyAndOrderFront(nil)
    sourceDidChange(url: url, kind: kind)
  }

  func sourceDidChange(url: URL?, kind: MediaInfoKind) {
    precondition(Thread.isMainThread)
    sourceURL = url
    sourceKind = kind
    invalidateRead()
    updateHeading()
    guard window?.isVisible == true, let url else {
      showEmptyState()
      updateButtons()
      return
    }
    beginRead(url: url, kind: kind)
  }

  override func close() {
    precondition(Thread.isMainThread)
    invalidateRead()
    showEmptyState()
    updateButtons()
    super.close()
  }

  func windowWillClose(_ notification: Notification) {
    invalidateRead()
    showEmptyState()
    updateButtons()
  }

  /// A separate pasteboard is injectable so tests never touch the user's clipboard.
  @discardableResult
  func copyAll(to pasteboard: NSPasteboard = .general) -> Bool {
    precondition(Thread.isMainThread)
    guard !isLoading, errorMessage == nil, let snapshot = displayedSnapshot else { return false }
    pasteboard.clearContents()
    return pasteboard.setString(snapshot.plainText, forType: .string)
  }

  @objc private func refreshInformation(_ sender: Any?) {
    guard let url = sourceURL, window?.isVisible == true else { return }
    sourceDidChange(url: url, kind: sourceKind)
  }

  @objc private func copyInformation(_ sender: Any?) { copyAll() }
  @objc private func closeInformation(_ sender: Any?) { close() }

  private func invalidateRead() {
    generation &+= 1
    cancellation?.cancel()
    cancellation = nil
    displayedSnapshot = nil
    errorMessage = nil
    isLoading = false
  }

  private func beginRead(url: URL, kind: MediaInfoKind) {
    let token = MediaInfoCancellation()
    cancellation = token
    let requestGeneration = generation
    let read = reader
    isLoading = true
    showStatus(title: mediaInfoText("window.loading", "Reading media information…"),
               message: nil, symbol: nil, spinning: true)
    updateButtons()
    readQueue.async { [weak self] in
      guard !token.isCancelled else { return }
      let result = Result { try read(url, kind, token) }
      DispatchQueue.main.async { [weak self] in
        guard let self, !token.isCancelled, self.generation == requestGeneration,
              self.window?.isVisible == true else { return }
        self.cancellation = nil
        self.isLoading = false
        switch result {
        case .success(let snapshot):
          self.displayedSnapshot = snapshot
          self.show(snapshot)
        case .failure(let error):
          self.errorMessage = error.localizedDescription
          self.showStatus(title: mediaInfoText("window.read_failed", "Unable to Read Information"),
                          message: error.localizedDescription, symbol: "exclamationmark.circle")
        }
        self.updateButtons()
      }
    }
  }

  private func updateHeading() {
    let name = sourceURL?.lastPathComponent ?? mediaInfoText("window.title", "Media Information")
    window?.title = name
    fileLabel.stringValue = name
    fileLabel.toolTip = sourceURL?.path
    kindImage.image = ChengYingStyle.symbol(sourceKind == .video ? "film" : "photo")
  }

  private func updateButtons() {
    refreshButton.isEnabled = sourceURL != nil && !isLoading
    copyButton.isEnabled = displayedSnapshot != nil && !isLoading && errorMessage == nil
  }

  private func buildInterface(in window: NSWindow) {
    let content = MediaInfoSurfaceView()
    window.contentView = content
    let title = NSTextField(labelWithString: mediaInfoText("window.title", "Media Information"))
    title.font = .systemFont(ofSize: 20, weight: .semibold)
    title.textColor = .labelColor
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    fileLabel.font = .systemFont(ofSize: 12)
    fileLabel.textColor = .secondaryLabelColor
    fileLabel.lineBreakMode = .byTruncatingMiddle
    fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let headings = verticalStack([title, fileLabel], spacing: 4)
    kindImage.contentTintColor = ChengYingStyle.accent
    kindImage.imageScaling = .scaleProportionallyUpOrDown
    kindImage.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([kindImage.widthAnchor.constraint(equalToConstant: 32),
                                 kindImage.heightAnchor.constraint(equalToConstant: 32)])
    let heading = NSStackView(views: [kindImage, headings])
    heading.spacing = 14
    heading.alignment = .centerY
    headings.widthAnchor.constraint(equalTo: heading.widthAnchor, constant: -46).isActive = true

    sectionsStack.orientation = .vertical
    sectionsStack.alignment = .leading
    sectionsStack.spacing = 12
    sectionsStack.translatesAutoresizingMaskIntoConstraints = false
    let document = MediaInfoDocumentView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(sectionsStack)
    scrollView.documentView = document
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.setAccessibilityLabel(mediaInfoText("window.title", "Media Information"))
    NSLayoutConstraint.activate([
      document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
      document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
      document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
      sectionsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
      sectionsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
      sectionsStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
      sectionsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
    ])

    refreshButton.title = mediaInfoText("window.refresh", "Refresh")
    refreshButton.image = ChengYingStyle.symbol("arrow.clockwise")
    refreshButton.imagePosition = .imageLeading
    refreshButton.target = self
    refreshButton.action = #selector(refreshInformation(_:))
    refreshButton.keyEquivalent = "r"
    refreshButton.keyEquivalentModifierMask = [.command]
    copyButton.title = mediaInfoText("window.copy_all", "Copy All")
    copyButton.image = ChengYingStyle.symbol("doc.on.doc")
    copyButton.imagePosition = .imageLeading
    copyButton.target = self
    copyButton.action = #selector(copyInformation(_:))
    closeButton.title = mediaInfoText("window.close", "Close")
    closeButton.target = self
    closeButton.action = #selector(closeInformation(_:))
    closeButton.keyEquivalent = "\u{1b}"
    closeButton.keyEquivalentModifierMask = []
    [refreshButton, copyButton].forEach(ChengYingStyle.secondaryButton)
    ChengYingStyle.primaryButton(closeButton)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let footer = NSStackView(views: [refreshButton, spacer, copyButton, closeButton])
    footer.spacing = 8
    footer.alignment = .centerY
    [heading, scrollView, footer].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview($0)
    }
    NSLayoutConstraint.activate([
      heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
      heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
      heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
      scrollView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18),
      scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
      footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
      footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
      footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
      footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
    ])
    updateHeading()
    updateButtons()
  }

  private func showEmptyState() {
    showStatus(title: mediaInfoText("window.no_source", "Open a video or image to see its information."),
               message: nil, symbol: "info.circle")
  }

  private func showStatus(title: String, message: String?, symbol: String?, spinning: Bool = false) {
    clearSections()
    let label = wrappingLabel(title, size: 13, weight: .medium)
    let leading: NSView
    if spinning {
      let indicator = NSProgressIndicator()
      indicator.style = .spinning
      indicator.controlSize = .small
      indicator.startAnimation(nil)
      leading = indicator
    } else {
      let image = NSImageView(image: ChengYingStyle.symbol(symbol ?? "info.circle"))
      image.contentTintColor = message == nil ? ChengYingStyle.accent : .secondaryLabelColor
      leading = image
    }
    leading.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([leading.widthAnchor.constraint(equalToConstant: 18),
                                 leading.heightAnchor.constraint(equalToConstant: 18)])
    let line = NSStackView(views: [leading, label])
    line.spacing = 10
    line.alignment = .top
    label.widthAnchor.constraint(equalTo: line.widthAnchor, constant: -28).isActive = true
    let stack = verticalStack([line], spacing: 8)
    if let message {
      let detail = wrappingLabel(message, size: 12)
      detail.textColor = .secondaryLabelColor
      stack.addArrangedSubview(detail)
      detail.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    addSection(ChengYingStyle.card(stack, insets: NSEdgeInsets(top: 18, left: 16, bottom: 18, right: 16)))
  }

  private func show(_ snapshot: MediaInfoSnapshot) {
    clearSections()
    for section in snapshot.content.sections {
      let title = wrappingLabel(section.title, size: 12, weight: .semibold)
      title.textColor = ChengYingStyle.accent
      let stack = verticalStack([title], spacing: 12)
      for row in section.rows {
        let label = wrappingLabel(row.label, size: 12)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let value = wrappingLabel(MediaInfoValue.text(row.value), size: 13)
        value.identifier = NSUserInterfaceItemIdentifier("media-info.\(row.id)")
        value.isSelectable = true
        value.setAccessibilityLabel(row.label)
        value.lineBreakMode = .byCharWrapping
        let line = NSStackView(views: [label, value])
        line.orientation = .horizontal
        line.alignment = .top
        line.spacing = 14
        value.widthAnchor.constraint(equalTo: line.widthAnchor, constant: -126).isActive = true
        stack.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      }
      addSection(ChengYingStyle.card(stack, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)))
    }
    for note in snapshot.content.notes {
      let label = wrappingLabel(note, size: 12)
      label.textColor = .secondaryLabelColor
      label.isSelectable = true
      addSection(label)
    }
    if snapshot.content.sections.isEmpty && snapshot.content.notes.isEmpty {
      showStatus(title: MediaInfoValue.unknown, message: nil, symbol: "info.circle")
    }
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  private func clearSections() {
    for view in sectionsStack.arrangedSubviews {
      sectionsStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }

  private func addSection(_ view: NSView) {
    view.translatesAutoresizingMaskIntoConstraints = false
    sectionsStack.addArrangedSubview(view)
    view.widthAnchor.constraint(equalTo: sectionsStack.widthAnchor).isActive = true
  }

  private func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    for view in views {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    return stack
  }

  private func wrappingLabel(_ text: String, size: CGFloat,
                             weight: NSFont.Weight = .regular) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = .labelColor
    label.maximumNumberOfLines = 0
    label.cell?.isScrollable = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }
}

/// Keep the media owner as the main window so playback menus retain their player.
private final class MediaInfoWindow: NSWindow {
  override var canBecomeMain: Bool { false }
}

private final class MediaInfoDocumentView: NSView {
  override var isFlipped: Bool { true }
}

private final class MediaInfoSurfaceView: NSView {
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    ChengYingStyle.surface.setFill()
    dirtyRect.fill()
  }
}
