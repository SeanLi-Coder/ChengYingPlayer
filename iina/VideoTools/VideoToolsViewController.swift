//
//  VideoToolsViewController.swift
//  ChengYing
//

import Cocoa

final class VideoToolsViewController: NSViewController, NSTextFieldDelegate {
  private static let maximumFrameRange = 5.0
  private static let maximumTimestampSeconds = 359_999_999.0
  private static let playbackSpeeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0, 8.0, 16.0]

  private weak var player: PlayerCore?
  private weak var mainWindow: MainWindowController?
  private let taskManager = VideoToolsTaskManager.shared

  private let sourceLabel = NSTextField(labelWithString: "")
  private let playbackPositionLabel = NSTextField(labelWithString: "")
  private let playbackControl = NSSegmentedControl(
    labels: [
      NSLocalizedString("videotools.playback.backward", comment: "Back five seconds"),
      NSLocalizedString("videotools.playback.play", comment: "Play"),
      NSLocalizedString("videotools.playback.forward", comment: "Forward five seconds"),
    ], trackingMode: .momentary, target: nil, action: nil
  )
  private let frameStepControl = NSSegmentedControl(
    labels: [
      NSLocalizedString("videotools.playback.previous_frame", comment: "Previous frame"),
      NSLocalizedString("videotools.playback.next_frame", comment: "Next frame"),
    ], trackingMode: .momentary, target: nil, action: nil
  )
  private let speedPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let slowerButton = NSButton(
    title: NSLocalizedString("videotools.playback.slower", comment: "Slower"), target: nil, action: nil
  )
  private let fasterButton = NSButton(
    title: NSLocalizedString("videotools.playback.faster", comment: "Faster"), target: nil, action: nil
  )
  private let rangeNavigationControl = NSSegmentedControl(
    labels: [
      NSLocalizedString("videotools.go_start", comment: "Go to start"),
      NSLocalizedString("videotools.go_end", comment: "Go to end"),
    ], trackingMode: .momentary, target: nil, action: nil
  )
  private let modeControl = NSSegmentedControl(
    labels: [
      NSLocalizedString("videotools.operation.clip", comment: "Clip video"),
      NSLocalizedString("videotools.operation.frames", comment: "Extract frames"),
      NSLocalizedString("videotools.operation.rotate", comment: "Rotate video"),
    ],
    trackingMode: .selectOne,
    target: nil,
    action: nil
  )
  private let startField = NSTextField(string: "")
  private let endField = NSTextField(string: "")
  private let setStartButton = NSButton(
    title: NSLocalizedString("videotools.set_start", comment: "Set start at current position"),
    target: nil,
    action: nil
  )
  private let setEndButton = NSButton(
    title: NSLocalizedString("videotools.set_end", comment: "Set end at current position"),
    target: nil,
    action: nil
  )
  private let rangePreviewButton = NSButton(
    title: NSLocalizedString("videotools.preview_range", comment: "Preview range"),
    target: nil,
    action: nil
  )
  private let frameHintLabel = NSTextField(labelWithString: "")
  private let rotationControl = NSSegmentedControl(
    labels: ["90°", "180°", "270°", "360°"],
    trackingMode: .selectOne,
    target: nil,
    action: nil
  )
  private let rotationPreviewButton = NSButton(
    title: NSLocalizedString("videotools.preview_rotation", comment: "Preview rotation"),
    target: nil,
    action: nil
  )
  private let outputField = NSTextField(string: "")
  private let chooseOutputButton = NSButton(
    title: NSLocalizedString("videotools.choose", comment: "Choose"),
    target: nil,
    action: nil
  )
  private let runButton = NSButton(
    title: NSLocalizedString("videotools.run", comment: "Run"),
    target: nil,
    action: nil
  )
  private let progressIndicator = NSProgressIndicator()
  private let statusLabel = NSTextField(labelWithString: "")
  private let timingLabel = NSTextField(labelWithString: "")
  private let cancelButton = NSButton(
    title: NSLocalizedString("general.cancel", comment: "Cancel"),
    target: nil,
    action: nil
  )
  private let revealButton = NSButton(
    title: NSLocalizedString("videotools.reveal", comment: "Show in Finder"),
    target: nil,
    action: nil
  )

  private var timeGroup: NSStackView!
  private var rotationGroup: NSStackView!
  private var outputGroup: NSStackView!
  private var previewTimer: Timer?
  private var playbackControlsTimer: Timer?
  private var previewSnapshot: VideoToolsPlayerSnapshot?
  private var outputDirectoryURL: URL?
  private var observedSourceURL: URL?
  private var observers: [NSObjectProtocol] = []
  private weak var toolsScrollView: NSScrollView?
  private weak var toolsDocumentView: NSView?
  private weak var contentStack: NSStackView?

  init(player: PlayerCore, mainWindow: MainWindowController) {
    self.player = player
    self.mainWindow = mainWindow
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    previewTimer?.invalidate()
    playbackControlsTimer?.invalidate()
    stopPreview(updateButton: false)
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  override func loadView() {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true

    let documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
    documentView.autoresizingMask = []
    scrollView.documentView = documentView

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.detachesHiddenViews = true
    stack.translatesAutoresizingMaskIntoConstraints = false
    documentView.addSubview(stack)

    let titleLabel = makeLabel(
      NSLocalizedString("videotools.title", comment: "Local video tools"),
      font: .boldSystemFont(ofSize: 14)
    )
    stack.addArrangedSubview(titleLabel)

    sourceLabel.lineBreakMode = .byTruncatingMiddle
    sourceLabel.textColor = .secondaryLabelColor
    sourceLabel.maximumNumberOfLines = 2
    stack.addArrangedSubview(sourceLabel)

    stack.addArrangedSubview(makePlaybackControls())
    stack.addArrangedSubview(makeSeparator())

    stack.addArrangedSubview(makeCaption(NSLocalizedString("videotools.mode", comment: "Mode")))
    modeControl.selectedSegment = 0
    modeControl.target = self
    modeControl.action = #selector(modeChanged(_:))
    modeControl.segmentStyle = .rounded
    stack.addArrangedSubview(modeControl)

    configureTimeFields()
    let startRow = makeTimeRow(
      title: NSLocalizedString("videotools.start", comment: "Start"),
      field: startField,
      button: setStartButton
    )
    let endRow = makeTimeRow(
      title: NSLocalizedString("videotools.end", comment: "End"),
      field: endField,
      button: setEndButton
    )
    rangePreviewButton.target = self
    rangePreviewButton.action = #selector(toggleRangePreview(_:))
    rangePreviewButton.bezelStyle = .rounded
    rangeNavigationControl.target = self
    rangeNavigationControl.action = #selector(navigateToRangeBoundary(_:))
    rangeNavigationControl.segmentDistribution = .fillEqually
    let markerHint = makeLabel(NSLocalizedString("videotools.markers_hint", comment: "How to select a range"))
    markerHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    markerHint.textColor = .secondaryLabelColor
    markerHint.maximumNumberOfLines = 0
    markerHint.lineBreakMode = .byWordWrapping
    timeGroup = makeVerticalGroup([
      startRow, endRow, rangeNavigationControl, rangePreviewButton, markerHint,
    ], spacing: 7)
    stack.addArrangedSubview(timeGroup)

    frameHintLabel.stringValue = NSLocalizedString("videotools.frames_hint", comment: "Frame extraction limit")
    frameHintLabel.textColor = .secondaryLabelColor
    frameHintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    frameHintLabel.maximumNumberOfLines = 2
    frameHintLabel.lineBreakMode = .byWordWrapping
    stack.addArrangedSubview(frameHintLabel)

    rotationControl.selectedSegment = 0
    rotationControl.target = self
    rotationControl.action = #selector(rotationChanged(_:))
    rotationPreviewButton.target = self
    rotationPreviewButton.action = #selector(toggleRotationPreview(_:))
    rotationPreviewButton.bezelStyle = .rounded
    rotationGroup = makeVerticalGroup([
      makeCaption(NSLocalizedString("videotools.rotation", comment: "Rotation")),
      rotationControl,
      rotationPreviewButton,
    ], spacing: 7)
    stack.addArrangedSubview(rotationGroup)

    outputField.isEditable = false
    outputField.isSelectable = true
    outputField.lineBreakMode = .byTruncatingMiddle
    outputField.placeholderString = NSLocalizedString("videotools.output_default", comment: "Same folder as source")
    chooseOutputButton.target = self
    chooseOutputButton.action = #selector(chooseOutputDirectory(_:))
    chooseOutputButton.bezelStyle = .rounded
    let outputRow = makeHorizontalGroup([outputField, chooseOutputButton], spacing: 7)
    outputField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    outputField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    outputGroup = makeVerticalGroup([
      makeCaption(NSLocalizedString("videotools.output_folder", comment: "Output folder")),
      outputRow,
    ], spacing: 6)
    stack.addArrangedSubview(outputGroup)

    runButton.target = self
    runButton.action = #selector(runTask(_:))
    runButton.bezelStyle = .rounded
    runButton.keyEquivalent = "\r"
    stack.addArrangedSubview(runButton)

    stack.addArrangedSubview(makeSeparator())

    progressIndicator.style = .bar
    progressIndicator.isIndeterminate = false
    progressIndicator.minValue = 0
    progressIndicator.maxValue = 100
    stack.addArrangedSubview(progressIndicator)

    statusLabel.maximumNumberOfLines = 3
    statusLabel.lineBreakMode = .byWordWrapping
    stack.addArrangedSubview(statusLabel)

    timingLabel.textColor = .secondaryLabelColor
    timingLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    stack.addArrangedSubview(timingLabel)

    cancelButton.target = self
    cancelButton.action = #selector(cancelTask(_:))
    cancelButton.bezelStyle = .rounded
    revealButton.target = self
    revealButton.action = #selector(revealOutput(_:))
    revealButton.bezelStyle = .rounded
    let taskButtons = makeHorizontalGroup([cancelButton, revealButton], spacing: 8)
    stack.addArrangedSubview(taskButtons)

    for arrangedView in stack.arrangedSubviews {
      arrangedView.translatesAutoresizingMaskIntoConstraints = false
      arrangedView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 14),
    ])

    toolsScrollView = scrollView
    toolsDocumentView = documentView
    contentStack = stack
    view = scrollView
    updateModeUI(resetFrameEnd: false)
    updateTaskUI()
    updatePlaybackControls()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    guard let scrollView = toolsScrollView,
          let documentView = toolsDocumentView,
          let stack = contentStack else { return }
    let visibleSize = scrollView.contentView.bounds.size
    guard visibleSize.width > 0 else { return }
    var frame = documentView.frame
    frame.size.width = visibleSize.width
    documentView.frame = frame
    documentView.layoutSubtreeIfNeeded()
    frame.size.height = max(visibleSize.height, stack.fittingSize.height + 30)
    if documentView.frame.size != frame.size {
      documentView.frame = frame
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    guard let player else { return }
    player.mpv.addHook(MPVHook.onUnLoad, hook: MPVHookValue(withBlock: { [weak self] next in
      guard self != nil else {
        next()
        return
      }
      DispatchQueue.main.async { [weak self] in
        self?.stopPreviewBeforeMediaUnload()
        next()
      }
    }))
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: .iinaFileLoaded, object: player, queue: .main) { [weak self] _ in
      self?.refreshCurrentMedia(force: true)
    })
    observers.append(center.addObserver(forName: .iinaPlayerStopped, object: player, queue: .main) { [weak self] _ in
      self?.refreshCurrentMedia(force: true)
    })
    observers.append(center.addObserver(forName: .videoToolsTaskChanged, object: taskManager, queue: .main) { [weak self] _ in
      self?.updateTaskUI()
    })
    refreshCurrentMedia(force: true)
  }

  func refreshCurrentMedia(force: Bool = false) {
    guard isViewLoaded else { return }
    let newURL = currentLocalMediaURL
    if force || newURL != observedSourceURL {
      stopPreview(updateButton: true)
      observedSourceURL = newURL
      outputDirectoryURL = newURL?.deletingLastPathComponent()
      updateOutputField()
      if let player, newURL != nil {
        let start = player.videoToolsCurrentTime ?? 0
        startField.stringValue = formatTimestamp(start, precision: 6)
        setDefaultEnd(after: start)
      } else {
        startField.stringValue = ""
        endField.stringValue = ""
      }
    }

    if let newURL {
      sourceLabel.stringValue = newURL.lastPathComponent
      sourceLabel.toolTip = newURL.path
    } else {
      sourceLabel.stringValue = NSLocalizedString("videotools.no_local_video", comment: "No local video")
      sourceLabel.toolTip = nil
    }
    updateTaskUI()
    updatePlaybackControls()
  }

  func stopPreview() {
    stopPreview(updateButton: true)
  }

  func setPlaybackControlsVisible(_ visible: Bool) {
    playbackControlsTimer?.invalidate()
    playbackControlsTimer = nil
    guard visible, isViewLoaded else { return }
    updatePlaybackControls()
    let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
      self?.updatePlaybackControls()
    }
    timer.tolerance = 0.05
    RunLoop.main.add(timer, forMode: .common)
    playbackControlsTimer = timer
  }

  // MARK: - Actions

  @objc private func playbackControlClicked(_ sender: NSSegmentedControl) {
    guard (0...2).contains(sender.selectedSegment), let player, player.info.state.loaded else { return }
    if sender.selectedSegment == 1 {
      previewTimer?.invalidate()
      previewTimer = nil
      player.togglePause()
    } else {
      guard let position = player.videoToolsCurrentTime else { return }
      stopPreview(updateButton: true, restorePlaybackState: false)
      player.videoToolsSeek(to: position + (sender.selectedSegment == 0 ? -5 : 5), pausePlayback: false)
    }
    updatePlaybackControls()
  }

  @objc private func stepFrame(_ sender: NSSegmentedControl) {
    guard (0...1).contains(sender.selectedSegment), let player, player.info.state.loaded else { return }
    stopPreview(updateButton: true, restorePlaybackState: false)
    player.pause()
    player.frameStep(backwards: sender.selectedSegment == 0)
    updatePlaybackControls()
  }

  @objc private func selectPlaybackSpeed(_ sender: NSPopUpButton) {
    guard let player, player.info.state.loaded,
          Self.playbackSpeeds.indices.contains(sender.indexOfSelectedItem) else { return }
    player.setSpeed(Self.playbackSpeeds[sender.indexOfSelectedItem])
    updatePlaybackControls()
  }

  @objc private func changePlaybackSpeed(_ sender: NSButton) {
    guard let player, player.info.state.loaded else { return }
    let currentSpeed = player.mpv.getDouble(MPVOption.PlaybackControl.speed)
    guard currentSpeed.isFinite else { return }
    let speed = sender === slowerButton
      ? Self.playbackSpeeds.last(where: { $0 < currentSpeed - 0.000_001 })
      : Self.playbackSpeeds.first(where: { $0 > currentSpeed + 0.000_001 })
    if let speed { player.setSpeed(speed) }
    updatePlaybackControls()
  }

  @objc private func navigateToRangeBoundary(_ sender: NSSegmentedControl) {
    guard (0...1).contains(sender.selectedSegment) else { return }
    let field = sender.selectedSegment == 0 ? startField : endField
    guard let target = parseTimestamp(field.stringValue), let player, player.info.state.loaded else { return }
    stopPreview(updateButton: true, restorePlaybackState: false)
    player.videoToolsSeek(to: target, pausePlayback: true)
    updatePlaybackControls()
  }

  @objc private func modeChanged(_ sender: NSSegmentedControl) {
    stopPreview(updateButton: true)
    updateModeUI(resetFrameEnd: selectedOperation == .frames)
  }

  @objc private func setStartToCurrentTime(_ sender: NSButton) {
    guard player?.info.state.loaded == true else { return }
    player?.pause()
    guard let currentTime = currentPlaybackTime else { return }
    stopPreview(updateButton: true, restorePlaybackState: false)
    startField.stringValue = formatTimestamp(currentTime, precision: 6)
    if selectedOperation == .frames || (parseTimestamp(endField.stringValue) ?? 0) <= currentTime {
      setDefaultEnd(after: currentTime)
    }
    updatePlaybackControls()
  }

  @objc private func setEndToCurrentTime(_ sender: NSButton) {
    guard player?.info.state.loaded == true else { return }
    player?.pause()
    guard let currentTime = currentPlaybackTime else { return }
    stopPreview(updateButton: true, restorePlaybackState: false)
    endField.stringValue = formatTimestamp(currentTime, precision: 6)
    _ = validatedRange(showError: true)
    updatePlaybackControls()
  }

  @objc private func toggleRangePreview(_ sender: NSButton) {
    if previewSnapshot != nil {
      stopPreview(updateButton: true)
    } else {
      previewRange(showValidationError: true)
    }
  }

  @objc private func rotationChanged(_ sender: NSSegmentedControl) {
    if previewSnapshot != nil, selectedOperation == .rotate {
      player?.videoToolsPreviewRotation(selectedRotation)
    }
  }

  @objc private func toggleRotationPreview(_ sender: NSButton) {
    guard selectedOperation == .rotate else { return }
    if previewSnapshot != nil {
      stopPreview(updateButton: true)
      return
    }
    guard let player, let snapshot = player.videoToolsCaptureSnapshot() else {
      showValidationError(NSLocalizedString("videotools.error.no_local_video", comment: "Open a local video first"))
      return
    }
    previewSnapshot = snapshot
    player.videoToolsPreviewRotation(selectedRotation)
    updatePreviewButtons()
  }

  @objc private func chooseOutputDirectory(_ sender: NSButton) {
    let panel = NSOpenPanel()
    panel.title = NSLocalizedString("videotools.choose_output", comment: "Choose output folder")
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.directoryURL = outputDirectoryURL ?? currentLocalMediaURL?.deletingLastPathComponent()
    let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.outputDirectoryURL = url
      self?.updateOutputField()
    }
    if let window = view.window {
      panel.beginSheetModal(for: window, completionHandler: completion)
    } else {
      completion(panel.runModal())
    }
  }

  @objc private func runTask(_ sender: NSButton) {
    guard let inputURL = currentLocalMediaURL else {
      showValidationError(NSLocalizedString("videotools.error.no_local_video", comment: "Open a local video first"))
      return
    }
    guard taskManager.snapshot?.isActive != true else {
      showValidationError(NSLocalizedString("videotools.error.busy", comment: "A video task is already running"))
      return
    }

    let operation = selectedOperation
    var start: Double?
    var end: Double?
    if operation == .clip || operation == .frames {
      guard let range = validatedRange(showError: true) else { return }
      start = range.start
      end = range.end
    }

    stopPreview(updateButton: true)
    do {
      try taskManager.start(
        operation: operation,
        inputURL: inputURL,
        start: start,
        end: end,
        degrees: operation == .rotate ? selectedRotation : nil,
        outputDirectory: operation == .rotate ? nil : outputDirectoryURL
      )
    } catch {
      showValidationError(error.localizedDescription)
    }
  }

  @objc private func cancelTask(_ sender: NSButton) {
    taskManager.cancelCurrent()
  }

  @objc private func revealOutput(_ sender: NSButton) {
    guard let outputURL = taskManager.snapshot?.outputURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
  }

  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSTextField,
          field === startField || field === endField else { return }
    if field === startField, selectedOperation == .frames, let start = parseTimestamp(startField.stringValue) {
      setDefaultEnd(after: start)
    }
    scheduleRangePreview()
  }

  // MARK: - Preview

  private func scheduleRangePreview() {
    previewTimer?.invalidate()
    guard selectedOperation == .clip || selectedOperation == .frames else { return }
    guard validatedRange(showError: false) != nil else {
      if previewSnapshot != nil {
        stopPreview(updateButton: true)
      }
      return
    }
    previewTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
      self?.previewRange(showValidationError: false)
    }
  }

  private func previewRange(showValidationError: Bool) {
    guard let range = validatedRange(showError: showValidationError), let player else { return }
    if previewSnapshot == nil {
      previewSnapshot = player.videoToolsCaptureSnapshot()
    }
    guard previewSnapshot != nil else {
      if showValidationError {
        self.showValidationError(NSLocalizedString("videotools.error.no_local_video", comment: "Open a local video first"))
      }
      return
    }
    player.videoToolsPreviewRange(start: range.start, end: range.end)
    updatePreviewButtons()
  }

  private func stopPreview(updateButton: Bool, restorePlaybackState: Bool = true) {
    previewTimer?.invalidate()
    previewTimer = nil
    if let previewSnapshot {
      player?.videoToolsRestoreSnapshot(previewSnapshot, restorePlaybackState: restorePlaybackState)
      self.previewSnapshot = nil
    }
    if updateButton, isViewLoaded {
      updatePreviewButtons()
    }
  }

  private func stopPreviewBeforeMediaUnload() {
    previewTimer?.invalidate()
    previewTimer = nil
    if let previewSnapshot {
      player?.videoToolsRestorePreviewBeforeUnload(previewSnapshot)
      self.previewSnapshot = nil
    }
    if isViewLoaded {
      updatePreviewButtons()
    }
  }

  private func updatePreviewButtons() {
    let isPreviewing = previewSnapshot != nil
    let stopTitle = NSLocalizedString("videotools.stop_preview", comment: "Stop preview")
    rangePreviewButton.title = isPreviewing ? stopTitle : NSLocalizedString("videotools.preview_range", comment: "Preview range")
    rotationPreviewButton.title = isPreviewing ? stopTitle : NSLocalizedString("videotools.preview_rotation", comment: "Preview rotation")
  }

  // MARK: - Validation and state

  private var selectedOperation: VideoToolsOperation {
    switch modeControl.selectedSegment {
    case 1: return .frames
    case 2: return .rotate
    default: return .clip
    }
  }

  private var selectedRotation: Int {
    [90, 180, 270, 360][max(0, rotationControl.selectedSegment)]
  }

  private var currentLocalMediaURL: URL? {
    guard let player,
          player.info.state.loaded,
          !player.info.isNetworkResource,
          let url = player.info.currentURL,
          url.isFileURL,
          FileManager.default.fileExists(atPath: url.path) else { return nil }
    return url
  }

  private var currentPlaybackTime: Double? {
    guard let player, currentLocalMediaURL != nil else { return nil }
    return player.videoToolsCurrentTime
  }

  private func validatedRange(showError: Bool) -> (start: Double, end: Double)? {
    guard let start = parseTimestamp(startField.stringValue),
          let end = parseTimestamp(endField.stringValue) else {
      if showError {
        showValidationError(NSLocalizedString("videotools.error.invalid_time", comment: "Enter a valid time"))
      }
      return nil
    }
    guard start >= 0, end > start else {
      if showError {
        showValidationError(NSLocalizedString("videotools.error.invalid_range", comment: "End must be after start"))
      }
      return nil
    }
    if let duration = player?.info.videoDuration?.second, end > duration + 0.001 {
      if showError {
        showValidationError(NSLocalizedString("videotools.error.after_duration", comment: "Range exceeds duration"))
      }
      return nil
    }
    if selectedOperation == .frames, end - start > Self.maximumFrameRange + 0.000_001 {
      if showError {
        showValidationError(NSLocalizedString("videotools.error.frames_too_long", comment: "Frame range exceeds five seconds"))
      }
      return nil
    }
    return (start, end)
  }

  private func parseTimestamp(_ rawValue: String) -> Double? {
    let text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = text
      .split(separator: ":", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count), !parts.contains(where: { $0.isEmpty }) else { return nil }

    func containsOnlyASCIIDigits(_ value: Substring) -> Bool {
      !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    let secondsComponents = parts.last!.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...2).contains(secondsComponents.count),
          containsOnlyASCIIDigits(secondsComponents[0]),
          secondsComponents.count == 1 ||
            (!secondsComponents[1].isEmpty && secondsComponents[1].count <= 6 &&
              containsOnlyASCIIDigits(secondsComponents[1])),
          parts.dropLast().allSatisfy(containsOnlyASCIIDigits),
          let secondsPart = Double(parts.last!),
          secondsPart.isFinite,
          secondsPart >= 0 else { return nil }
    if parts.count > 1, secondsPart >= 60 { return nil }
    var total = secondsPart
    if parts.count >= 2 {
      guard let minutes = Double(parts[parts.count - 2]), minutes.isFinite, minutes >= 0 else { return nil }
      if parts.count == 3, minutes >= 60 { return nil }
      total += minutes * 60
    }
    if parts.count == 3 {
      guard let hours = Double(parts[0]), hours.isFinite, hours >= 0 else { return nil }
      total += hours * 3600
    }
    guard total.isFinite, total <= Self.maximumTimestampSeconds else { return nil }
    return (total * 1_000_000).rounded() / 1_000_000
  }

  private func setDefaultEnd(after start: Double) {
    let duration = player?.info.videoDuration?.second ?? (start + Self.maximumFrameRange)
    let end = max(start, min(start + Self.maximumFrameRange, duration))
    endField.stringValue = formatTimestamp(end, precision: 6)
  }

  private func formatTimestamp(_ seconds: Double, precision: Int = 3) -> String {
    guard seconds.isFinite else { return "--:--.---" }
    let precision = min(6, max(1, precision))
    let scale = Int(pow(10, Double(precision)))
    let ticks = Int((min(Self.maximumTimestampSeconds, max(0, seconds)) * Double(scale)).rounded())
    let totalSeconds = ticks / scale
    let hours = totalSeconds / 3600
    let minutes = totalSeconds % 3600 / 60
    let remainingSeconds = totalSeconds % 60
    let time = String(format: "%02d:%02d.%0\(precision)d", minutes, remainingSeconds, ticks % scale)
    return hours > 0 ? "\(hours):\(time)" : time
  }

  private func updateModeUI(resetFrameEnd: Bool) {
    let operation = selectedOperation
    timeGroup.isHidden = operation == .rotate
    frameHintLabel.isHidden = operation != .frames
    rotationGroup.isHidden = operation != .rotate
    outputGroup.isHidden = operation == .rotate
    if resetFrameEnd, let start = parseTimestamp(startField.stringValue) {
      setDefaultEnd(after: start)
    }
    switch operation {
    case .clip:
      runButton.title = NSLocalizedString("videotools.run_clip", comment: "Create clip")
    case .frames:
      runButton.title = NSLocalizedString("videotools.run_frames", comment: "Extract frames")
    case .rotate:
      runButton.title = NSLocalizedString("videotools.run_rotate", comment: "Create rotated video")
    case .probe:
      runButton.title = NSLocalizedString("videotools.run", comment: "Run")
    }
    updatePreviewButtons()
  }

  private func updateTaskUI() {
    guard isViewLoaded else { return }
    let active = taskManager.snapshot?.isActive == true
    runButton.isEnabled = currentLocalMediaURL != nil && !active
    cancelButton.isHidden = !active
    cancelButton.isEnabled = taskManager.snapshot?.phase != .cancelling
    revealButton.isHidden = taskManager.snapshot?.outputURL == nil

    guard let task = taskManager.snapshot else {
      progressIndicator.doubleValue = 0
      statusLabel.textColor = .secondaryLabelColor
      statusLabel.stringValue = NSLocalizedString("videotools.status.ready", comment: "Ready")
      timingLabel.stringValue = ""
      return
    }

    progressIndicator.doubleValue = task.progress
    let format = NSLocalizedString("videotools.status.task", comment: "Task status format")
    statusLabel.stringValue = String(
      format: format,
      task.operation.localizedName,
      task.inputURL.lastPathComponent,
      task.message
    )
    statusLabel.textColor = task.phase == .failed ? .systemRed : .labelColor

    var timingParts: [String] = []
    if let elapsed = task.elapsedSeconds {
      timingParts.append(String(
        format: NSLocalizedString("videotools.elapsed", comment: "Elapsed time"),
        formatDuration(elapsed)
      ))
    }
    if let eta = task.etaSeconds, task.isActive {
      timingParts.append(String(
        format: NSLocalizedString("videotools.eta", comment: "Estimated remaining time"),
        formatDuration(eta)
      ))
    }
    if let frameCount = task.frameCount {
      timingParts.append(String(
        format: NSLocalizedString("videotools.frames_count", comment: "Frame count"),
        frameCount
      ))
    }
    timingLabel.stringValue = timingParts.joined(separator: "  ·  ")
  }

  private func formatDuration(_ rawSeconds: Double) -> String {
    guard rawSeconds.isFinite, rawSeconds >= 0 else {
      return NSLocalizedString("general.na", comment: "N/A")
    }
    let total = Int(rawSeconds.rounded())
    let hours = total / 3600
    let minutes = total % 3600 / 60
    let seconds = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
  }

  private func updateOutputField() {
    outputField.stringValue = outputDirectoryURL?.path ?? ""
    outputField.toolTip = outputDirectoryURL?.path
  }

  private func showValidationError(_ message: String) {
    statusLabel.stringValue = message
    statusLabel.textColor = .systemRed
  }

  // MARK: - UI construction

  private func makePlaybackControls() -> NSStackView {
    playbackPositionLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    playbackPositionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    playbackControl.target = self
    playbackControl.action = #selector(playbackControlClicked(_:))
    frameStepControl.target = self
    frameStepControl.action = #selector(stepFrame(_:))
    for control in [playbackControl, frameStepControl] {
      control.segmentDistribution = .fillEqually
      control.segmentStyle = .rounded
    }
    for speed in Self.playbackSpeeds {
      speedPopup.addItem(withTitle: playbackSpeedTitle(speed))
    }
    speedPopup.target = self
    speedPopup.action = #selector(selectPlaybackSpeed(_:))
    speedPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
    speedPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    speedPopup.setAccessibilityLabel(NSLocalizedString("videotools.playback.speed", comment: "Playback speed"))
    for button in [slowerButton, fasterButton] {
      button.target = self
      button.action = #selector(changePlaybackSpeed(_:))
      button.bezelStyle = .rounded
    }
    let speedHint = makeLabel(NSLocalizedString("videotools.playback.speed_hint", comment: "Playback speed does not change exports"))
    speedHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    speedHint.textColor = .secondaryLabelColor
    speedHint.maximumNumberOfLines = 0
    speedHint.lineBreakMode = .byWordWrapping
    return makeVerticalGroup([
      makeCaption(NSLocalizedString("videotools.playback.title", comment: "Playback and positioning")),
      playbackPositionLabel,
      playbackControl,
      frameStepControl,
      makeCaption(NSLocalizedString("videotools.playback.speed", comment: "Playback speed")),
      makeHorizontalGroup([slowerButton, speedPopup, fasterButton], spacing: 7),
      speedHint,
    ], spacing: 7)
  }

  private func playbackSpeedTitle(_ speed: Double) -> String {
    if speed == 1 {
      return NSLocalizedString("videotools.playback.normal_speed", comment: "Normal playback speed")
    }
    return String(format: "%g×", speed)
  }

  private func updatePlaybackControls() {
    guard isViewLoaded else { return }
    let loaded = player?.info.state.loaded == true
    let localMediaLoaded = loaded && currentLocalMediaURL != nil
    playbackControl.isEnabled = loaded
    frameStepControl.isEnabled = loaded && player?.info.vid != nil && player?.info.vid != 0
    speedPopup.isEnabled = loaded
    for control in [startField, endField, setStartButton, setEndButton, rangePreviewButton, rotationPreviewButton] as [NSControl] {
      control.isEnabled = localMediaLoaded
    }
    for (index, field) in [startField, endField].enumerated() {
      let target = parseTimestamp(field.stringValue)
      let withinDuration = target.map { $0 <= (player?.info.videoDuration?.second ?? .infinity) } ?? false
      rangeNavigationControl.setEnabled(localMediaLoaded && withinDuration, forSegment: index)
    }
    guard loaded, let player else {
      playbackPositionLabel.stringValue = "--:--.--- / --:--.---"
      playbackControl.setLabel(NSLocalizedString("videotools.playback.play", comment: "Play"), forSegment: 1)
      slowerButton.isEnabled = false
      fasterButton.isEnabled = false
      return
    }
    let position = player.videoToolsCurrentTime.map { formatTimestamp($0) } ?? "--:--.---"
    let duration = player.info.videoDuration?.second
    let durationText = duration.flatMap { $0.isFinite && $0 >= 0 ? formatTimestamp($0) : nil } ?? "--:--.---"
    playbackPositionLabel.stringValue = "\(position) / \(durationText)"
    let paused = player.mpv.getFlag(MPVOption.PlaybackControl.pause)
    playbackControl.setLabel(NSLocalizedString(
      paused ? "videotools.playback.play" : "videotools.playback.pause", comment: "Play or pause"
    ), forSegment: 1)
    let speed = player.mpv.getDouble(MPVOption.PlaybackControl.speed)
    guard speed.isFinite, speed > 0 else { return }
    slowerButton.isEnabled = speed > Self.playbackSpeeds[0]
    fasterButton.isEnabled = speed < Self.playbackSpeeds[Self.playbackSpeeds.count - 1]
    if let index = Self.playbackSpeeds.firstIndex(where: { abs($0 - speed) < 0.000_001 }) {
      speedPopup.selectItem(at: index)
      if speedPopup.numberOfItems > Self.playbackSpeeds.count {
        speedPopup.removeItem(at: Self.playbackSpeeds.count)
      }
    } else {
      let title = playbackSpeedTitle(speed)
      if speedPopup.numberOfItems == Self.playbackSpeeds.count {
        speedPopup.addItem(withTitle: title)
      }
      speedPopup.item(at: Self.playbackSpeeds.count)?.title = title
      speedPopup.item(at: Self.playbackSpeeds.count)?.isEnabled = false
      speedPopup.selectItem(at: Self.playbackSpeeds.count)
    }
  }

  private func configureTimeFields() {
    for field in [startField, endField] {
      field.delegate = self
      field.placeholderString = "00:00.000"
      field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
      field.setContentHuggingPriority(.defaultLow, for: .horizontal)
      field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    setStartButton.target = self
    setStartButton.action = #selector(setStartToCurrentTime(_:))
    setStartButton.bezelStyle = .rounded
    setEndButton.target = self
    setEndButton.action = #selector(setEndToCurrentTime(_:))
    setEndButton.bezelStyle = .rounded
  }

  private func makeTimeRow(title: String, field: NSTextField, button: NSButton) -> NSStackView {
    let label = makeLabel(title)
    label.alignment = .right
    label.widthAnchor.constraint(equalToConstant: 42).isActive = true
    return makeHorizontalGroup([label, field, button], spacing: 7)
  }

  private func makeLabel(_ value: String, font: NSFont? = nil) -> NSTextField {
    let label = NSTextField(labelWithString: value)
    label.font = font
    return label
  }

  private func makeCaption(_ value: String) -> NSTextField {
    let label = makeLabel(value, font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold))
    label.textColor = .secondaryLabelColor
    return label
  }

  private func makeHorizontalGroup(_ views: [NSView], spacing: CGFloat) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.distribution = .fill
    stack.spacing = spacing
    return stack
  }

  private func makeVerticalGroup(_ views: [NSView], spacing: CGFloat) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.distribution = .fill
    stack.spacing = spacing
    stack.detachesHiddenViews = true
    for view in views {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    return stack
  }

  private func makeSeparator() -> NSBox {
    let separator = NSBox()
    separator.boxType = .separator
    return separator
  }
}
