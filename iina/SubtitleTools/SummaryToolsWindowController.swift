import Cocoa
import UniformTypeIdentifiers

private final class SummaryToolsWindow: NSWindow {
  override var canBecomeMain: Bool { false }
  override var canBecomeKey: Bool { true }
}

/// Source acquisition shares the downloader configuration; inference stays in the subtitle helper.
final class SummaryToolsWindowController: NSWindowController {
  let sourceField = NSTextField()
  let startButton = NSButton()
  let cancelButton = NSButton()
  let downloadCenterButton = NSButton()
  let prepareButton = NSButton()
  let copyButton = NSButton()
  let exportButton = NSButton()
  let licenseButton = NSButton()
  let modelLabel = NSTextField(wrappingLabelWithString: "")
  let statusLabel = NSTextField(wrappingLabelWithString: "")
  let countLabel = NSTextField(labelWithString: "")
  let progress = NSProgressIndicator()
  let resultView = NSTextView()
  private let service: SubtitleToolsService
  private let openDownloadCenter: () -> Void
  private let copyText: (String) -> Void
  private let openModelLicense: () -> Void
  private let chooseExport: ((NSWindow, @escaping (URL?) -> Void) -> Void)?
  private var observer: NSObjectProtocol?
  private var displayedResultID: String?
  private var observedSummaryID: String?
  private(set) var resultText = ""

  init(service: SubtitleToolsService = .shared, openDownloadCenter: @escaping () -> Void,
       copyText: @escaping (String) -> Void = { text in
         NSPasteboard.general.clearContents()
         NSPasteboard.general.setString(text, forType: .string)
       }, chooseExport: ((NSWindow, @escaping (URL?) -> Void) -> Void)? = nil,
       openModelLicense: @escaping () -> Void = {
         NSWorkspace.shared.open(URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!)
       }) {
    self.service = service
    self.openDownloadCenter = openDownloadCenter
    self.copyText = copyText
    self.chooseExport = chooseExport
    self.openModelLicense = openModelLicense
    let window = SummaryToolsWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 780),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                    backing: .buffered, defer: false)
    window.title = summaryToolsString("title")
    window.contentMinSize = NSSize(width: 760, height: 700)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    buildContent()
    observer = NotificationCenter.default.addObserver(forName: .subtitleToolsChanged, object: service, queue: .main) {
      [weak self] _ in self?.render()
    }
    render()
    window.center()
  }

  required init?(coder: NSCoder) { nil }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    // Closing a window must not cancel the shared background task.
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(sender)
    service.refreshStatus()
    render()
  }

  private func text(_ key: String, size: CGFloat = 12) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: summaryToolsString(key))
    label.font = .systemFont(ofSize: size)
    label.textColor = .secondaryLabelColor
    label.maximumNumberOfLines = 0
    label.preferredMaxLayoutWidth = 680
    label.isSelectable = true
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    return label
  }

  private func button(_ button: NSButton, _ key: String, _ action: Selector, primary: Bool = false) {
    button.title = summaryToolsString(key)
    button.identifier = NSUserInterfaceItemIdentifier("summary.\(key)")
    button.target = self
    button.action = action
    button.translatesAutoresizingMaskIntoConstraints = false
    if primary { ChengYingStyle.primaryButton(button) } else { ChengYingStyle.secondaryButton(button) }
  }

  private func row(_ buttons: [NSButton]) -> NSView {
    let row = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false
    var previous: NSButton?
    for button in buttons {
      row.addSubview(button)
      NSLayoutConstraint.activate([
        button.topAnchor.constraint(equalTo: row.topAnchor),
        button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        button.leadingAnchor.constraint(equalTo: previous?.trailingAnchor ?? row.leadingAnchor,
                                        constant: previous == nil ? 0 : 10)
      ])
      if let first = buttons.first, first !== button {
        button.widthAnchor.constraint(equalTo: first.widthAnchor).isActive = true
      }
      previous = button
    }
    previous?.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
    row.heightAnchor.constraint(equalToConstant: 34).isActive = true
    return row
  }

  private func buildContent() {
    guard let content = window?.contentView else { return }
    let heading = ChengYingStyle.heading(summaryToolsString("title"), subtitle: summaryToolsString("intro"))
    sourceField.placeholderString = summaryToolsString("source.placeholder")
    sourceField.identifier = NSUserInterfaceItemIdentifier("summary.source")
    sourceField.setAccessibilityLabel(summaryToolsString("source.label"))
    sourceField.font = .systemFont(ofSize: 13)
    sourceField.lineBreakMode = .byTruncatingMiddle
    sourceField.target = self
    sourceField.action = #selector(startSummary)
    sourceField.translatesAutoresizingMaskIntoConstraints = false
    sourceField.heightAnchor.constraint(equalToConstant: 28).isActive = true
    button(startButton, "start", #selector(startSummary), primary: true)
    button(cancelButton, "cancel", #selector(cancelTask))
    button(downloadCenterButton, "download_center", #selector(showDownloadCenter))
    downloadCenterButton.toolTip = summaryToolsString("download_center.hint")
    button(prepareButton, "models.download", #selector(prepareModels))
    button(copyButton, "copy", #selector(copyResult))
    button(exportButton, "export", #selector(exportResult))
    button(licenseButton, "models.license", #selector(showLicense))
    let actions = row([startButton, cancelButton, downloadCenterButton])

    modelLabel.identifier = NSUserInterfaceItemIdentifier("summary.models")
    modelLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    modelLabel.maximumNumberOfLines = 0
    modelLabel.preferredMaxLayoutWidth = 680
    modelLabel.isSelectable = true
    modelLabel.translatesAutoresizingMaskIntoConstraints = false
    modelLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    let modelContents = NSView()
    let modelActions = row([prepareButton, licenseButton])
    modelContents.addSubview(modelLabel)
    modelContents.addSubview(modelActions)
    NSLayoutConstraint.activate([
      modelLabel.leadingAnchor.constraint(equalTo: modelContents.leadingAnchor),
      modelLabel.trailingAnchor.constraint(equalTo: modelContents.trailingAnchor),
      modelLabel.topAnchor.constraint(equalTo: modelContents.topAnchor),
      modelActions.leadingAnchor.constraint(equalTo: modelContents.leadingAnchor),
      modelActions.trailingAnchor.constraint(equalTo: modelContents.trailingAnchor),
      modelActions.topAnchor.constraint(equalTo: modelLabel.bottomAnchor, constant: 8),
      modelActions.bottomAnchor.constraint(equalTo: modelContents.bottomAnchor)
    ])
    let models = ChengYingStyle.card(modelContents)
    statusLabel.identifier = NSUserInterfaceItemIdentifier("summary.status")
    statusLabel.font = .systemFont(ofSize: 12)
    statusLabel.maximumNumberOfLines = 3
    statusLabel.preferredMaxLayoutWidth = 680
    statusLabel.isSelectable = true
    statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    countLabel.textColor = .secondaryLabelColor
    countLabel.lineBreakMode = .byTruncatingTail
    countLabel.identifier = NSUserInterfaceItemIdentifier("summary.counts")
    progress.style = .bar
    progress.minValue = 0
    progress.maxValue = 100
    let resultScroll = NSScrollView()
    resultScroll.hasVerticalScroller = true
    resultScroll.autohidesScrollers = true
    resultScroll.borderType = .bezelBorder
    resultView.isEditable = false
    resultView.isSelectable = true
    resultView.isRichText = false
    resultView.isAutomaticLinkDetectionEnabled = false
    resultView.isAutomaticDataDetectionEnabled = false
    resultView.isAutomaticTextReplacementEnabled = false
    resultView.importsGraphics = false
    resultView.font = .systemFont(ofSize: 13)
    resultView.textColor = .textColor
    resultView.textContainerInset = NSSize(width: 14, height: 12)
    resultView.textContainer?.widthTracksTextView = true
    resultView.isHorizontallyResizable = false
    resultView.isVerticallyResizable = true
    resultView.autoresizingMask = [.width]
    resultView.identifier = NSUserInterfaceItemIdentifier("summary.result")
    resultView.setAccessibilityLabel(summaryToolsString("result.label"))
    resultScroll.documentView = resultView
    let resultActions = row([copyButton, exportButton])
    let disclaimer = text("limitations", size: 11)
    disclaimer.identifier = NSUserInterfaceItemIdentifier("summary.limitations")
    let sections: [NSView] = [heading, sourceField, actions, models, statusLabel, progress,
                              countLabel, resultScroll, resultActions, disclaimer]
    var previous: NSView?
    for view in sections {
      view.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(view)
      NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
        view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        view.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? content.topAnchor,
                                  constant: previous == nil ? 20 : 10)
      ])
      previous = view
    }
    resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
    progress.heightAnchor.constraint(equalToConstant: 12).isActive = true
    countLabel.heightAnchor.constraint(equalToConstant: 14).isActive = true
    disclaimer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18).isActive = true
    window?.initialFirstResponder = sourceField
  }

  private var summaryTask: SubtitleToolsTask? {
    guard let task = service.task, task.operation == .summary || task.purpose == "summary" else { return nil }
    return task
  }

  private func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
  }

  private func render() {
    let task = summaryTask
    let busy = service.task?.isActive == true
    sourceField.isEnabled = !busy
    startButton.isEnabled = service.hardware.canGenerate && service.summaryReady && !busy
    prepareButton.isEnabled = service.hardware.supportsRuntime && !busy
    cancelButton.isEnabled = task?.isActive == true && task?.phase != .cancelling
    let models = service.summaryModels
    let complete = models.allSatisfy { $0.totalBytes > 0 && $0.downloadedBytes >= $0.totalBytes }
    let partial = models.contains { $0.downloadedBytes > 0 && !$0.ready }
    prepareButton.title = summaryToolsString(complete ? "models.verify" : partial ? "models.resume" : "models.download")
    modelLabel.stringValue = models.map { model in
      let total = model.totalBytes > 0 ? bytes(model.totalBytes) : summaryToolsString("models.unknown")
      return "\(model.name) · \(bytes(model.downloadedBytes)) / \(total) · \(summaryToolsString(model.ready ? "models.ready" : "models.pending"))"
    }.joined(separator: "\n")
    if let task, task.operation == .summary, observedSummaryID != task.id {
      observedSummaryID = task.id
      resultText = ""
      resultView.string = ""
    }
    if let task, task.phase == .completed, let text = task.summaryText, displayedResultID != task.id {
      displayedResultID = task.id
      resultText = text
      resultView.string = text
      resultView.scrollToBeginningOfDocument(nil)
    }
    copyButton.isEnabled = !resultText.isEmpty
    exportButton.isEnabled = !resultText.isEmpty
    progress.isIndeterminate = task?.isActive == true && task?.progress == nil
    if progress.isIndeterminate { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    progress.minValue = 0
    progress.maxValue = 100
    progress.doubleValue = (task?.progress ?? 0) * 100
    progress.needsDisplay = true
    statusLabel.textColor = .labelColor
    if !service.hardware.supportsRuntime { statusLabel.stringValue = summaryToolsString("error.hardware") }
    else if !service.hardware.canGenerate, task == nil { statusLabel.stringValue = SummaryToolsError.insufficientMemory.localizedDescription }
    else if busy, task == nil { statusLabel.stringValue = summaryToolsString("status.other_task") }
    else if let task {
      let phase: String
      switch task.phase {
      case .starting: phase = "status.starting"
      case .running: phase = "status.running"
      case .cancelling: phase = "status.cancelling"
      case .completed: phase = "status.completed"
      case .failed: phase = "status.failed"
      case .cancelled: phase = "status.cancelled"
      }
      var parts = [summaryToolsString(phase)]
      if let stage = task.stage {
        let localized = summaryToolsString("stage.\(stage)")
        let fallback = subtitleToolsString("stage.\(stage)")
        parts.append(localized != "stage.\(stage)" ? localized
                     : fallback != "stage.\(stage)" ? fallback : summaryToolsString("status.running"))
      }
      if let error = task.error { parts.append(String(error.prefix(1500))); statusLabel.textColor = .systemRed }
      parts.append(contentsOf: task.warnings.prefix(4).map { String($0.prefix(500)) })
      statusLabel.stringValue = parts.joined(separator: " · ")
    } else {
      statusLabel.stringValue = service.statusError ?? summaryToolsString(service.summaryReady ? "status.ready" : "status.needs_models")
    }
    statusLabel.toolTip = statusLabel.stringValue
    var counts = [String]()
    if let task {
      if task.totalBytes > 0 { counts.append("\(bytes(task.downloadedBytes)) / \(bytes(task.totalBytes))") }
      if let speed = task.bytesPerSecond, speed > 0 { counts.append("\(bytes(Int64(min(speed, Double(Int64.max / 2)))))/s") }
      if let tokens = task.tokensGenerated { counts.append(String(format: summaryToolsString("counts.tokens"), tokens)) }
      if let index = task.chunkIndex, let total = task.chunkCount {
        counts.append(String(format: summaryToolsString("counts.chunks"), index, total))
      }
      if let elapsed = task.elapsedSeconds { counts.append(String(format: summaryToolsString("counts.elapsed"), elapsed)) }
      if let eta = task.etaSeconds { counts.append(String(format: summaryToolsString("counts.eta"), eta)) }
      if let fraction = task.progress, task.isActive { counts.append(String(format: summaryToolsString("counts.progress"), fraction * 100)) }
    }
    countLabel.stringValue = counts.joined(separator: " · ")
    countLabel.toolTip = countLabel.stringValue
    window?.contentView?.layoutSubtreeIfNeeded()
  }

  @objc private func startSummary() {
    do { _ = try service.summarize(source: sourceField.stringValue) }
    catch { statusLabel.stringValue = error.localizedDescription; statusLabel.textColor = .systemRed }
  }

  @objc private func prepareModels() {
    do { _ = try service.prepareSummaryModels() }
    catch { statusLabel.stringValue = error.localizedDescription; statusLabel.textColor = .systemRed }
  }

  @objc private func cancelTask() {
    guard summaryTask?.isActive == true else { return }
    service.cancelCurrent()
  }

  @objc private func showDownloadCenter() { openDownloadCenter() }
  @objc private func showLicense() { openModelLicense() }
  @objc private func copyResult() { if !resultText.isEmpty { copyText(resultText) } }

  @objc private func exportResult() {
    guard !resultText.isEmpty, let window,
          let lease = UpdateWorkAdmission.shared.beginActivity(reason: "busy.subtitles") else { return }
    let text = resultText
    let finish: (URL?) -> Void = { [weak self] url in
      defer { UpdateWorkAdmission.shared.endActivity(lease) }
      guard let url else { return }
      do { try text.write(to: url, atomically: true, encoding: .utf8) }
      catch { self?.statusLabel.stringValue = error.localizedDescription }
    }
    if let chooseExport { chooseExport(window, finish) }
    else {
      let panel = NSSavePanel()
      if #available(macOS 11.0, *) { panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText] }
      panel.nameFieldStringValue = summaryToolsString("export.filename")
      panel.beginSheetModal(for: window) { response in finish(response == .OK ? panel.url : nil) }
    }
  }
}
