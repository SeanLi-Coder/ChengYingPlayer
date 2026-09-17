import Cocoa

private final class SubtitleToolsDocumentView: NSView {
  override var isFlipped: Bool { true }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    ChengYingStyle.surface.setFill()
    dirtyRect.fill()
  }
}

final class SubtitleToolsViewController: NSViewController {
  private static let languages = ["auto", "zh", "yue", "en", "ja", "ko"]
  private weak var player: PlayerCore?
  private let service: SubtitleToolsService
  private var observers = [NSObjectProtocol]()
  private var ownedTaskID: String?
  private var ownedMediaGeneration: UInt64?
  private var handledCompletionID: String?
  private let tabs = NSSegmentedControl(labels: [subtitleToolsString("tab.generate"), subtitleToolsString("tab.models")], trackingMode: .selectOne, target: nil, action: nil)
  private let sourceLabel = NSTextField(labelWithString: "")
  private let hardwareLabel = NSTextField(labelWithString: "")
  private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let burnCheckbox = NSButton(checkboxWithTitle: subtitleToolsString("generate.burn"), target: nil, action: nil)
  private let generateButton = NSButton(title: subtitleToolsString("generate.run"), target: nil, action: nil)
  private let prepareButton = NSButton(title: subtitleToolsString("models.download"), target: nil, action: nil)
  private let cancelButton = NSButton(title: subtitleToolsString("task.cancel"), target: nil, action: nil)
  private let revealButton = NSButton(title: subtitleToolsString("task.reveal"), target: nil, action: nil)
  private let statusLabel = NSTextField(labelWithString: "")
  private let rateLabel = NSTextField(labelWithString: "")
  private let progress = NSProgressIndicator()
  private var generationGroup: NSStackView!
  private var modelsGroup: NSStackView!
  private var modelLabels = [String: NSTextField]()
  private var modelProgress = [String: NSProgressIndicator]()
  private weak var scrollView: NSScrollView?
  private weak var documentView: NSView?
  private weak var contentStack: NSStackView?

  init(player: PlayerCore, service: SubtitleToolsService = .shared) {
    self.player = player
    self.service = service
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
    // Closing a panel does not stop the shared background task.
  }

  override func loadView() {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let document = SubtitleToolsDocumentView(frame: NSRect(x: 0, y: 0, width: 340, height: 700))
    scroll.documentView = document
    let stack = vertical([])
    stack.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 14),
    ])
    stack.spacing = 14
    stack.addArrangedSubview(ChengYingStyle.heading(subtitleToolsString("title"), subtitle: subtitleToolsString("heading.subtitle")))
    tabs.selectedSegment = 0
    tabs.target = self
    tabs.action = #selector(tabChanged(_:))
    tabs.segmentDistribution = .fillEqually
    ChengYingStyle.segmented(tabs)
    stack.addArrangedSubview(tabs)
    styleDescription(hardwareLabel)
    stack.addArrangedSubview(hardwareLabel)

    styleDescription(sourceLabel)
    sourceLabel.font = .systemFont(ofSize: 14, weight: .medium)
    sourceLabel.maximumNumberOfLines = 1
    sourceLabel.lineBreakMode = .byTruncatingMiddle
    sourceLabel.setAccessibilityLabel(subtitleToolsString("generate.source"))
    for code in Self.languages { languagePopup.addItem(withTitle: subtitleToolsString("language.\(code)")) }
    languagePopup.setAccessibilityLabel(subtitleToolsString("generate.language"))
    if #available(macOS 11.0, *) { languagePopup.controlSize = .large }
    languagePopup.font = .systemFont(ofSize: 13)
    burnCheckbox.state = .off
    burnCheckbox.font = .systemFont(ofSize: 12)
    burnCheckbox.lineBreakMode = .byWordWrapping
    configure(generateButton, action: #selector(generate(_:)))
    ChengYingStyle.primaryButton(generateButton)
    generateButton.image = ChengYingStyle.symbol("captions.bubble")
    generateButton.imagePosition = .imageLeading
    let sourceCard = ChengYingStyle.card(vertical([
      sectionLabel(subtitleToolsString("generate.source")), sourceLabel,
    ]))
    let optionsCard = ChengYingStyle.card(vertical([
      sectionLabel(subtitleToolsString("generate.options")),
      label(subtitleToolsString("generate.language"), secondary: true), languagePopup,
      burnCheckbox,
      label(subtitleToolsString("generate.external_hint"), secondary: true),
    ]))
    generationGroup = vertical([
      sourceCard,
      optionsCard,
      generateButton,
      label(subtitleToolsString("generate.quality_hint"), secondary: true),
    ])
    generationGroup.spacing = 14
    stack.addArrangedSubview(generationGroup)

    var modelViews: [NSView] = [label(subtitleToolsString("models.fixed"), secondary: true)]
    for model in SubtitleToolsModel.fixedModels {
      let role = sectionLabel(subtitleToolsString("models.role.\(model.id)"))
      role.textColor = ChengYingStyle.accent
      let name = label(model.name)
      name.font = .systemFont(ofSize: 13, weight: .semibold)
      let details = label("")
      details.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
      details.textColor = .secondaryLabelColor
      let bar = NSProgressIndicator()
      bar.style = .bar
      bar.controlSize = .small
      bar.isIndeterminate = false
      bar.minValue = 0
      bar.maxValue = 1
      modelLabels[model.id] = details
      modelProgress[model.id] = bar
      modelViews.append(ChengYingStyle.card(vertical([role, name, details, bar])))
    }
    configure(prepareButton, action: #selector(prepare(_:)))
    ChengYingStyle.primaryButton(prepareButton)
    prepareButton.image = ChengYingStyle.symbol("arrow.down.circle")
    prepareButton.imagePosition = .imageLeading
    modelViews.append(prepareButton)
    modelViews.append(label(subtitleToolsString("models.resume_hint"), secondary: true))
    let qwenLicense = NSButton(title: "Qwen · Apache 2.0", target: self, action: #selector(openQwenLicense(_:)))
    let hyLicense = NSButton(title: "HY-MT2 · Tencent Hy Community License", target: self, action: #selector(openHYLicense(_:)))
    for button in [qwenLicense, hyLicense] {
      ChengYingStyle.secondaryButton(button)
      button.font = .systemFont(ofSize: 10, weight: .medium)
      button.image = ChengYingStyle.symbol("arrow.up.right")
      button.imagePosition = .imageTrailing
    }
    modelViews.append(ChengYingStyle.card(vertical([
      sectionLabel(subtitleToolsString("models.licenses")),
      label(subtitleToolsString("models.license_hint"), secondary: true), qwenLicense, hyLicense,
    ])))
    modelsGroup = vertical(modelViews)
    modelsGroup.spacing = 12
    modelsGroup.isHidden = true
    stack.addArrangedSubview(modelsGroup)
    progress.style = .bar
    progress.controlSize = .small
    progress.minValue = 0
    progress.maxValue = 1
    styleDescription(statusLabel)
    styleDescription(rateLabel)
    rateLabel.textColor = .secondaryLabelColor
    rateLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    configure(cancelButton, action: #selector(cancel(_:)))
    configure(revealButton, action: #selector(reveal(_:)))
    ChengYingStyle.secondaryButton(cancelButton)
    ChengYingStyle.secondaryButton(revealButton)
    stack.addArrangedSubview(ChengYingStyle.card(vertical([
      sectionLabel(subtitleToolsString("task.heading")), statusLabel, progress, rateLabel,
      cancelButton, revealButton,
    ])))
    for child in stack.arrangedSubviews {
      child.translatesAutoresizingMaskIntoConstraints = false
      child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    scrollView = scroll
    documentView = document
    contentStack = stack
    view = scroll
    updateUI()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    observers.append(NotificationCenter.default.addObserver(forName: .subtitleToolsChanged, object: service, queue: .main) { [weak self] _ in
      self?.updateUI()
      self?.loadCompletedSubtitleIfAppropriate()
    })
    if let player {
      for name in [Notification.Name.iinaFileLoaded, .iinaPlayerStopped] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
          self?.refreshCurrentMedia()
        })
      }
    }
    service.refreshStatus()
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    service.refreshStatus()
    updateUI()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    guard let scrollView, let documentView, let contentStack else { return }
    let size = scrollView.contentView.bounds.size
    guard size.width > 0 else { return }
    documentView.setFrameSize(NSSize(width: size.width, height: documentView.frame.height))
    documentView.layoutSubtreeIfNeeded()
    documentView.setFrameSize(NSSize(width: size.width, height: max(size.height, contentStack.fittingSize.height + 30)))
  }

  func refreshCurrentMedia() { if isViewLoaded { updateUI() } }

  @objc private func tabChanged(_ sender: NSSegmentedControl) {
    generationGroup.isHidden = sender.selectedSegment != 0
    modelsGroup.isHidden = sender.selectedSegment != 1
    service.refreshStatus()
    updateUI()
    scrollView?.contentView.scroll(to: .zero)
    view.needsLayout = true
  }

  @objc private func generate(_ sender: NSButton) {
    guard let input = currentMediaURL, let player,
          Self.languages.indices.contains(languagePopup.indexOfSelectedItem) else {
      showError(SubtitleToolsError.invalidInput.localizedDescription)
      return
    }
    do {
      ownedMediaGeneration = player.videoToolsMediaGeneration
      ownedTaskID = try service.start(inputURL: input, language: Self.languages[languagePopup.indexOfSelectedItem], burnSubtitles: burnCheckbox.state == .on)
      handledCompletionID = nil
      updateUI()
    } catch { showError(error.localizedDescription) }
  }

  @objc private func prepare(_ sender: NSButton) {
    let alert = NSAlert()
    alert.messageText = subtitleToolsString("models.confirm_title")
    alert.informativeText = subtitleToolsString("models.confirm_body")
    alert.addButton(withTitle: subtitleToolsString("models.download"))
    alert.addButton(withTitle: subtitleToolsString("task.cancel"))
    let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard response == .alertFirstButtonReturn, let self else { return }
      do { try self.service.prepareModels() } catch { self.showError(error.localizedDescription) }
    }
    if let window = view.window { alert.beginSheetModal(for: window, completionHandler: complete) }
    else { complete(alert.runModal()) }
  }

  @objc private func cancel(_ sender: NSButton) { service.cancelCurrent() }

  @objc private func reveal(_ sender: NSButton) {
    guard let task = service.task else { return }
    let urls = [task.assURL, task.srtURL, task.videoURL].compactMap { $0 }
    if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
  }

  @objc private func openQwenLicense(_ sender: NSButton) {
    NSWorkspace.shared.open(URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!)
  }

  @objc private func openHYLicense(_ sender: NSButton) {
    NSWorkspace.shared.open(URL(string: "https://huggingface.co/tencent/Hy-MT2-30B-A3B/blob/main/LICENSE.txt")!)
  }

  private var currentMediaURL: URL? {
    guard let player, player.info.state.loaded, !player.info.isNetworkResource,
          let url = player.info.currentURL, url.isFileURL,
          player.info.vid != nil, player.info.vid != 0,
          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
    return url.standardizedFileURL.resolvingSymlinksInPath()
  }

  private func loadCompletedSubtitleIfAppropriate() {
    guard let task = service.task, task.phase == .completed, task.operation == .subtitles,
          task.id == ownedTaskID, handledCompletionID != task.id else { return }
    handledCompletionID = task.id
    guard let player, player.videoToolsMediaGeneration == ownedMediaGeneration,
          task.inputURL == currentMediaURL, let ass = task.assURL,
          FileManager.default.fileExists(atPath: ass.path) else { return }
    // Selecting explicitly also covers players whose previous subtitle track was disabled.
    player.mpv.command(.subAdd, args: [ass.path, "select"], checkError: false)
    player.mpv.setFlag(MPVOption.Subtitles.subVisibility, true)
  }

  private func updateUI() {
    guard isViewLoaded else { return }
    sourceLabel.stringValue = currentMediaURL?.lastPathComponent ?? subtitleToolsString("generate.no_video")
    sourceLabel.toolTip = currentMediaURL?.path
    if !service.hardware.supportsRuntime {
      hardwareLabel.stringValue = SubtitleToolsError.unsupportedHardware.localizedDescription
    } else if !service.hardware.canGenerate {
      hardwareLabel.stringValue = SubtitleToolsError.insufficientMemory.localizedDescription
    } else {
      hardwareLabel.stringValue = subtitleToolsString("hardware.ready")
    }
    hardwareLabel.textColor = service.hardware.canGenerate ? .secondaryLabelColor : .systemOrange
    let task = service.task
    let active = task?.isActive == true
    generateButton.isEnabled = currentMediaURL != nil && service.hardware.canGenerate && service.isReady && !active
    languagePopup.isEnabled = !active
    burnCheckbox.isEnabled = !active
    prepareButton.isEnabled = service.hardware.supportsRuntime && !active
    let partial = service.subtitleModels.contains { $0.downloadedBytes > 0 && !$0.ready }
    let completeBytes = service.subtitleModels.allSatisfy { $0.totalBytes > 0 && $0.downloadedBytes >= $0.totalBytes }
    prepareButton.title = subtitleToolsString(service.isReady || completeBytes ? "models.verify" : partial ? "models.resume" : "models.download")
    cancelButton.isHidden = !active
    cancelButton.isEnabled = task?.phase != .cancelling
    cancelButton.title = subtitleToolsString(task?.operation == .prepare ? "models.pause" : "task.cancel")
    revealButton.isHidden = task?.assURL == nil && task?.srtURL == nil && task?.videoURL == nil
    for model in service.models {
      let total = model.totalBytes > 0 ? bytes(model.totalBytes) : subtitleToolsString("models.unknown_size")
      let state = subtitleToolsString(model.ready ? "models.ready" : "models.not_ready")
      modelLabels[model.id]?.stringValue = "\(bytes(model.downloadedBytes)) / \(total) · \(state)"
      modelProgress[model.id]?.doubleValue = model.ready ? 1 : model.totalBytes > 0 ? min(1, Double(model.downloadedBytes) / Double(model.totalBytes)) : 0
    }
    progress.isIndeterminate = active && task?.progress == nil
    if progress.isIndeterminate { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    progress.doubleValue = task?.progress ?? 0
    progress.isHidden = !active && task?.phase != .completed
    statusLabel.textColor = task?.phase == .failed || service.statusError != nil ? .systemRed : .labelColor
    if let task {
      let phaseKey: String
      switch task.phase {
      case .starting: phaseKey = "status.starting"
      case .running: phaseKey = "status.running"
      case .cancelling: phaseKey = "status.cancelling"
      case .completed: phaseKey = task.warnings.isEmpty ? "status.completed" : "status.partial"
      case .failed: phaseKey = "status.failed"
      case .cancelled: phaseKey = task.operation == .prepare ? "status.paused" : "status.cancelled"
      }
      var parts = [subtitleToolsString(phaseKey)]
      if let input = task.inputURL { parts.append(input.lastPathComponent) }
      if let stage = task.stage { parts.append(stageTitle(stage)) }
      if let error = task.error { parts.append(error) }
      parts.append(contentsOf: task.warnings)
      if task.phase == .completed, !task.warnings.isEmpty { statusLabel.textColor = .systemOrange }
      statusLabel.stringValue = parts.joined(separator: "\n")
      var timing = [String]()
      if task.totalBytes > 0 { timing.append("\(bytes(task.downloadedBytes)) / \(bytes(task.totalBytes))") }
      if let rate = task.bytesPerSecond, rate > 0 { timing.append("\(bytes(Int64(min(rate, Double(Int64.max) / 2))))/s") }
      if let seconds = task.etaSeconds {
        let key = task.etaScope == "remaining_download" ? "task.eta.download"
          : task.etaScope == "current_file_verification" ? "task.eta.verify" : "task.eta"
        timing.append(String(format: subtitleToolsString(key), duration(seconds)))
      }
      else if task.isActive { timing.append(subtitleToolsString("task.estimating")) }
      rateLabel.stringValue = timing.joined(separator: " · ")
    } else {
      statusLabel.stringValue = service.statusError ?? subtitleToolsString(service.isReady ? "status.ready" : "status.needs_models")
      rateLabel.stringValue = ""
    }
    rateLabel.isHidden = rateLabel.stringValue.isEmpty
    view.needsLayout = true
  }

  private func stageTitle(_ stage: String) -> String {
    let key = "stage.\(stage)"
    let translated = subtitleToolsString(key)
    return translated == key ? stage : translated
  }

  private func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
  }

  private func duration(_ seconds: Double) -> String {
    let total = Int(min(Double(Int.max / 2), max(0, seconds)).rounded())
    if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
    return String(format: "%02d:%02d", total / 60, total % 60)
  }

  private func showError(_ message: String) {
    statusLabel.stringValue = message
    statusLabel.textColor = .systemRed
  }

  private func configure(_ button: NSButton, action: Selector) {
    button.target = self
    button.action = action
    button.bezelStyle = .rounded
  }

  private func label(_ text: String, secondary: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    styleDescription(field)
    if secondary { field.textColor = .secondaryLabelColor }
    return field
  }

  private func sectionLabel(_ text: String) -> NSTextField {
    let field = label(text)
    field.font = .systemFont(ofSize: 11, weight: .semibold)
    return field
  }

  private func styleDescription(_ field: NSTextField) {
    field.maximumNumberOfLines = 0
    field.lineBreakMode = .byWordWrapping
    field.font = .systemFont(ofSize: 12)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.required, for: .vertical)
  }

  private func vertical(_ children: [NSView]) -> NSStackView {
    let stack = NSStackView(views: children)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.detachesHiddenViews = true
    for child in children {
      child.translatesAutoresizingMaskIntoConstraints = false
      child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    return stack
  }
}
