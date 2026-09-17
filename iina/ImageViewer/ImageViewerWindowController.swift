import Cocoa

/// Native image viewing is isolated from the media playback state machine.
final class ImageViewerWindowController: NSWindowController, NSWindowDelegate,
                                         NSTableViewDataSource, NSTableViewDelegate {
  private struct Details {
    let width: Int
    let height: Int
    let frameCount: Int
    let isAnimated: Bool
    let loopCount: Int
    let formatName: String
    let bitDepth: Int
    let hasAlpha: Bool
  }

  let canvas = ImageCanvasView(frame: .zero)
  let tableView = NSTableView()
  let statusLabel = NSTextField(labelWithString: "打开图片，开始浏览")
  let frameLabel = NSTextField(labelWithString: "")
  let zoomLabel = NSTextField(labelWithString: "适应窗口")
  let mediaInfoButton = NSButton(title: mediaInfoText("action.info", "Info"), target: nil, action: nil)
  let animationButton = NSButton(title: "播放动图", target: nil, action: nil)
  let previousButton = NSButton(title: "上一张", target: nil, action: nil)
  let nextButton = NSButton(title: "下一张", target: nil, action: nil)
  let previousFrameButton = NSButton(title: "上一帧 / 页", target: nil, action: nil)
  let nextFrameButton = NSButton(title: "下一帧 / 页", target: nil, action: nil)
  let formatPicker = NSPopUpButton(frame: .zero, pullsDown: false)
  let convertButton = NSButton(title: "转换并另存", target: nil, action: nil)
  let cancelButton = NSButton(title: "取消转换", target: nil, action: nil)
  let revealButton = NSButton(title: "在 Finder 显示", target: nil, action: nil)
  let viewOutputButton = NSButton(title: "查看结果", target: nil, action: nil)
  let progressIndicator = NSProgressIndicator()
  let sortPicker = NSPopUpButton(frame: .zero, pullsDown: false)
  let folderLabel = NSTextField(labelWithString: "当前文件夹")
  let slideshowButton = NSButton(title: "播放幻灯片", target: nil, action: nil)
  let intervalField = NSTextField(string: "5")
  let intervalSlider = NSSlider(value: log(5), minValue: log(0.5), maxValue: log(120), target: nil, action: nil)
  let intervalStepper = NSStepper()
  let loopSlideshowButton = NSButton(checkboxWithTitle: "循环播放", target: nil, action: nil)
  private let fullscreenButton = NSButton(title: "全屏", target: nil, action: nil)
  private let directionButton = NSButton(title: "↑", target: nil, action: nil)
  private let titleLabel = NSTextField(labelWithString: "图片")
  private let infoLabel = NSTextField(labelWithString: "")
  private(set) var files: [PlaylistFileMetadata] = []
  private(set) var selectedURL: URL?
  private(set) var frameIndex = 0
  private(set) var isAnimating = false
  private(set) var isBusy = false
  private(set) var lastOutputURL: URL?
  private var details: Details?
  private var sourceGeneration = UUID()
  private var listGeneration = UUID()
  private var frameGeneration = UUID()
  private var conversionGeneration = UUID()
  private var conversionToken: ImageCancellationToken?
  private var sourceToken = ImageCancellationToken()
  private var listToken = ImageCancellationToken()
  private var frameToken = ImageCancellationToken()
  private var closed = false
  private var ascending = true
  private var sortRequested = false
  private var directoryURL: URL?
  private var selectingRow = false
  private var timer: Timer?
  private var animationDeadline: CFTimeInterval?
  private var completedLoops = 0
  private var frameDuration: TimeInterval = 0.1
  private var framePending = false
  private var formats: [ImageConversionFormat] = []
  private var wasAnimatingBeforeMiniaturize = false
  private var wasSlideshowRunningBeforeMiniaturize = false
  private var slideshow = ImageSlideshowPolicy()
  private var slideshowTimer: Timer?
  private var isListing = false
  private let defaults: UserDefaults
  private static let intervalPreference = "ChengYing.ImageSlideshow.Interval"
  private static let loopPreference = "ChengYing.ImageSlideshow.Loop"
  var isSlideshowRunning: Bool { slideshow.isRunning }
  var isActiveForUpdate: Bool { isBusy || slideshow.isRunning || wasSlideshowRunningBeforeMiniaturize }
  var slideshowInterval: TimeInterval { slideshow.interval }
  private let listQueue = DispatchQueue(label: "io.chengying.image.list", qos: .userInitiated)
  private let decodeQueue = DispatchQueue(label: "io.chengying.image.decode", qos: .userInitiated)
  private let conversionQueue = DispatchQueue(label: "io.chengying.image.convert", qos: .userInitiated)
  // Everything below is confined to decodeQueue.
  private var queueDocument: ImageDocument?
  private var queueDocumentGeneration: UUID?
  private var cachedFrames: [Int: CGImage] = [:]
  private var cachedOrder: [Int] = []
  private let maximumFrameBytes = 64 * 1024 * 1024

  init(urls: [URL], defaults: UserDefaults = .standard) {
    self.defaults = defaults
    super.init(window: nil)
    if let saved = defaults.object(forKey: Self.intervalPreference) as? NSNumber {
      slideshow.setInterval(saved.doubleValue, now: CACurrentMediaTime())
    }
    loadWindow()
    loadFormats()
    open(urls: urls)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    window?.makeFirstResponder(canvas)
  }

  override func loadWindow() {
    guard window == nil else { return }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    window.title = "澄影视界 · 图片"
    window.contentMinSize = NSSize(width: 880, height: 620)
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.setFrameAutosaveName("ChengYingImageViewer")
    self.window = window
    let content = NSView()
    window.contentView = content
    titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
    titleLabel.lineBreakMode = .byTruncatingMiddle
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    infoLabel.font = .systemFont(ofSize: 11)
    infoLabel.textColor = .secondaryLabelColor
    let heading = stack([titleLabel, infoLabel], vertical: true, spacing: 3)
    mediaInfoButton.bezelStyle = .rounded
    mediaInfoButton.target = self
    mediaInfoButton.action = #selector(showMediaInfo)
    mediaInfoButton.toolTip = mediaInfoText("action.info_hint", "Original media details (Command-I)")
    mediaInfoButton.setAccessibilityLabel(mediaInfoText("action.media_info", "Media Information…"))
    let top = stack([heading, spacer(), button("−", #selector(zoomOut)),
                     zoomLabel, button("+", #selector(zoomIn)),
                     button("适应窗口", #selector(fit)), button("100%", #selector(actualSize)), mediaInfoButton])
    content.addSubview(top)

    sortPicker.addItems(withTitles: ["名称", "文件大小", "修改日期", "创建日期"])
    sortPicker.target = self
    sortPicker.action = #selector(sortChanged)
    directionButton.target = self
    directionButton.action = #selector(reverseSort)
    let sidebarHeading = stack([sortPicker, directionButton, button("刷新", #selector(refreshList))])
    folderLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    folderLabel.lineBreakMode = .byTruncatingMiddle
    folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("image"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.rowHeight = 68
    tableView.intercellSpacing = NSSize(width: 0, height: 2)
    tableView.dataSource = self
    tableView.delegate = self
    tableView.allowsEmptySelection = true
    tableView.setAccessibilityLabel("同目录图片与 Finder 标签")
    let scroll = NSScrollView()
    scroll.documentView = tableView
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    let sidebar = stack([folderLabel, sidebarHeading, scroll], vertical: true, spacing: 8)
    sidebar.widthAnchor.constraint(equalToConstant: 248).isActive = true
    folderLabel.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
    sidebarHeading.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
    scroll.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
    canvas.translatesAutoresizingMaskIntoConstraints = false
    let body = stack([canvas, sidebar], spacing: 14)
    body.alignment = .top
    content.addSubview(body)
    canvas.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
    sidebar.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
    sidebar.setHuggingPriority(.defaultLow, for: .vertical)
    scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    let navigation = stack([previousButton, nextButton, spacer(), previousFrameButton,
                            frameLabel, nextFrameButton, animationButton])
    [previousButton, nextButton, previousFrameButton, nextFrameButton, animationButton,
     convertButton, cancelButton, revealButton, viewOutputButton].forEach { $0.target = self; $0.bezelStyle = .rounded }
    previousButton.action = #selector(previousImage)
    nextButton.action = #selector(nextImage)
    previousFrameButton.action = #selector(previousFrame)
    nextFrameButton.action = #selector(nextFrame)
    animationButton.action = #selector(toggleAnimation)
    slideshowButton.target = self
    slideshowButton.action = #selector(toggleSlideshow)
    slideshowButton.bezelStyle = .rounded
    slideshowButton.toolTip = "按当前列表顺序自动切换图片（S）；动图仍按自己的帧时长播放。"
    intervalField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    intervalField.alignment = .right
    intervalField.target = self
    intervalField.action = #selector(intervalTextChanged)
    intervalField.setAccessibilityLabel("幻灯片每张停留秒数")
    intervalField.toolTip = "0.5–120 秒；输入后按回车生效，播放中也可调整。"
    intervalField.widthAnchor.constraint(equalToConstant: 52).isActive = true
    intervalStepper.minValue = 0.5
    intervalStepper.maxValue = 120
    intervalStepper.increment = 0.5
    intervalStepper.valueWraps = false
    intervalStepper.target = self
    intervalStepper.action = #selector(intervalStepChanged)
    intervalStepper.setAccessibilityLabel("增减幻灯片秒数")
    intervalSlider.target = self
    intervalSlider.action = #selector(intervalSliderChanged)
    intervalSlider.isContinuous = true
    intervalSlider.setAccessibilityLabel("调整幻灯片停留时间")
    intervalSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
    intervalSlider.widthAnchor.constraint(lessThanOrEqualToConstant: 230).isActive = true
    intervalSlider.toolTip = "拖动立即调整；每张图片完全显示后才开始计时。"
    loopSlideshowButton.state = (defaults.object(forKey: Self.loopPreference) as? NSNumber)?.boolValue == false ? .off : .on
    loopSlideshowButton.target = self
    loopSlideshowButton.action = #selector(loopSlideshowChanged)
    fullscreenButton.target = self
    fullscreenButton.action = #selector(toggleImageFullscreen)
    fullscreenButton.bezelStyle = .rounded
    let slideshowBar = stack([slideshowButton, NSTextField(labelWithString: "每张"), intervalField,
                               NSTextField(labelWithString: "秒"), intervalStepper, intervalSlider,
                               loopSlideshowButton, spacer(), fullscreenButton])
    updateIntervalControls()
    convertButton.action = #selector(confirmConversion)
    cancelButton.action = #selector(cancelConversion)
    revealButton.action = #selector(revealOutput)
    viewOutputButton.action = #selector(viewOutput)
    formatPicker.addItem(withTitle: "正在检测编码器…")
    let conversion = stack([NSTextField(labelWithString: "另存格式"), formatPicker, convertButton,
                            cancelButton, progressIndicator, viewOutputButton, revealButton])
    progressIndicator.isIndeterminate = false
    progressIndicator.minValue = 0
    progressIndicator.maxValue = 100
    progressIndicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
    statusLabel.font = .systemFont(ofSize: 11)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.lineBreakMode = .byTruncatingMiddle
    statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let note = NSTextField(wrappingLabelWithString:
      "原图不覆盖，保存到同级目录。跨格式可能改变位深、HDR、色彩并移除 EXIF / GPS。JXL、PSD、RAW 等仅供读取；可转换格式取决于系统与内置编码器。")
    note.font = .systemFont(ofSize: 10)
    note.textColor = .secondaryLabelColor
    let footer = stack([navigation, slideshowBar, conversion, statusLabel, note], vertical: true, spacing: 8)
    footer.alignment = .leading
    content.addSubview(footer)
    navigation.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
    slideshowBar.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
    conversion.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
    statusLabel.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
    note.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
    NSLayoutConstraint.activate([
      top.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
      top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
      top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
      top.heightAnchor.constraint(equalToConstant: 48),
      body.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12),
      body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
      body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
      body.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
      footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
      footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
      footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
    ])
    canvas.onZoomChanged = { [weak self] value in
      self?.zoomLabel.stringValue = String(format: "%.0f%%", value * 100)
    }
    canvas.onNavigate = { [weak self] offset in self?.navigate(offset) }
    canvas.onToggleAnimation = { [weak self] in self?.toggleAnimation() }
    canvas.onToggleSlideshow = { [weak self] in self?.toggleSlideshow() }
    canvas.onDropURLs = { urls in _ = PlayerCore.openURLs(urls) }
    updateControls()
    window.center()
  }

  private func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = vertical ? .vertical : .horizontal
    stack.alignment = vertical ? .leading : .centerY
    stack.spacing = spacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }
  private func spacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return view
  }
  private func button(_ title: String, _ action: Selector) -> NSButton {
    let result = NSButton(title: title, target: self, action: action)
    result.bezelStyle = .rounded
    return result
  }

  func open(urls: [URL]) {
    guard !UpdateWorkAdmission.shared.isBlocked else { return }
    closed = false
    stopSlideshow()
    wasAnimatingBeforeMiniaturize = false
    let accepted = urls.filter { $0.isFileURL && ImageFileSupport.isImageURL($0) }
    guard let first = accepted.first else { return }
    directoryURL = accepted.count == 1 ? first.deletingLastPathComponent() : nil
    sortRequested = false
    ascending = true
    directionButton.title = "↑"
    sortPicker.selectItem(at: 0)
    listGeneration = UUID()
    listToken.cancel()
    listToken = ImageCancellationToken()
    let token = listToken
    let generation = listGeneration
    isListing = true
    files = accepted.map { PlaylistFileMetadata(url: $0) }
    tableView.reloadData()
    load(first)
    listQueue.async { [weak self] in
      guard !token.isCancelled else { return }
      let candidates: [URL]
      if accepted.count == 1 {
        candidates = ((try? FileManager.default.contentsOfDirectory(
          at: first.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey],
          options: [.skipsHiddenFiles])) ?? []).filter {
            !token.isCancelled && ImageFileSupport.isImageURL($0) &&
              ((try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true)
          }
      } else { candidates = accepted }
      guard !token.isCancelled else { return }
      let firstIdentity = first.standardizedFileURL.resolvingSymlinksInPath()
      var seen = Set<URL>()
      let uniqueCandidates = candidates.compactMap { candidate -> URL? in
        guard !token.isCancelled else { return nil }
        let identity = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard seen.insert(identity).inserted else { return nil }
        return identity == firstIdentity ? first : candidate
      }
      var metadata = uniqueCandidates.compactMap { candidate -> PlaylistFileMetadata? in
        token.isCancelled ? nil : PlaylistFileMetadata.read(from: candidate)
      }
      guard !token.isCancelled else { return }
      if !seen.contains(firstIdentity) { metadata.append(PlaylistFileMetadata.read(from: first)) }
      if accepted.count == 1 {
        metadata = PlaylistFileMetadata.sortedIndices(for: metadata).map { metadata[$0] }
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.closed, self.listGeneration == generation else { return }
        self.isListing = false
        self.files = metadata
        if self.sortRequested { self.applySort(); return }
        self.tableView.reloadData()
        self.selectCurrentRow()
        self.updateControls()
      }
    }
  }

  private func load(_ url: URL) {
    slideshowTimer?.invalidate()
    slideshowTimer = nil
    slideshow.imageWillLoad()
    stopAnimation()
    sourceToken.cancel()
    sourceToken = ImageCancellationToken()
    let token = sourceToken
    frameToken.cancel()
    sourceGeneration = UUID()
    frameGeneration = UUID()
    let generation = sourceGeneration
    selectedURL = url
    NotificationCenter.default.post(name: .chengyingImageSourceChanged, object: self)
    frameIndex = 0
    completedLoops = 0
    framePending = true
    details = nil
    canvas.display(nil, resetZoom: true)
    titleLabel.stringValue = url.lastPathComponent
    infoLabel.stringValue = "正在读取图片…"
    if !isBusy { statusLabel.stringValue = "正在后台解码…" }
    window?.representedURL = url
    window?.title = "\(url.lastPathComponent) — 澄影视界"
    selectCurrentRow()
    updateControls()
    decodeQueue.async { [weak self] in
      guard !token.isCancelled, let self else { return }
      self.queueDocument = nil
      self.queueDocumentGeneration = generation
      self.cachedFrames.removeAll()
      self.cachedOrder.removeAll()
      do {
        let document = try ImageDocument(url: url)
        guard !token.isCancelled else { return }
        let image = try document.frame(at: 0)
        guard !token.isCancelled else { return }
        self.queueDocument = document
        self.cache(image, at: 0)
        let info = Details(width: document.width, height: document.height, frameCount: document.frameCount,
                           isAnimated: document.isAnimated, loopCount: document.loopCount,
                           formatName: document.formatName, bitDepth: document.bitDepth, hasAlpha: document.hasAlpha)
        let duration = document.frameDuration(at: 0)
        DispatchQueue.main.async { [weak self] in
          guard let self, !self.closed, self.sourceGeneration == generation else { return }
          self.details = info
          self.framePending = false
          self.frameDuration = self.validDuration(duration)
          self.canvas.display(image, resetZoom: true)
          if Preference.bool(for: .recordRecentFiles) { AppDelegate.shared.noteNewRecentDocumentURL(url) }
          self.infoLabel.stringValue = "\(info.width) × \(info.height) · \(info.formatName) · \(info.bitDepth)-bit\(info.hasAlpha ? " · 透明通道" : "")"
          if !self.isBusy { self.statusLabel.stringValue = "滚轮 / 双指缩放 · 拖动平移 · ← → 切换 · 0 适应 · 1 原始像素" }
          self.updateControls()
          if info.isAnimated { self.startAnimation() }
          if self.slideshow.isRunning {
            self.slideshow.imageDidDisplay(now: CACurrentMediaTime())
            self.scheduleSlideshow()
          }
        }
      } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self, !self.closed, self.sourceGeneration == generation else { return }
          self.framePending = false
          self.infoLabel.stringValue = "无法打开图片"
          self.statusLabel.stringValue = error.localizedDescription
          self.updateControls()
          self.handleSlideshowFailure(url: url)
        }
      }
    }
  }

  private func cache(_ image: CGImage, at index: Int) {
    let bytes = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
    guard !bytes.overflow, bytes.partialValue <= maximumFrameBytes else { return }
    cachedFrames[index] = image
    cachedOrder.removeAll { $0 == index }
    cachedOrder.append(index)
    while cachedOrder.count > 3 || cachedFrames.values.reduce(0, { $0 + $1.bytesPerRow * $1.height }) > maximumFrameBytes {
      cachedFrames.removeValue(forKey: cachedOrder.removeFirst())
    }
  }

  private func requestFrame(_ index: Int) {
    guard let details, (0..<details.frameCount).contains(index), !closed else { return }
    framePending = true
    frameGeneration = UUID()
    let request = frameGeneration
    let generation = sourceGeneration
    let documentToken = sourceToken
    frameToken.cancel()
    frameToken = ImageCancellationToken()
    let token = frameToken
    updateControls()
    decodeQueue.async { [weak self] in
      guard !token.isCancelled, !documentToken.isCancelled,
            let self, self.queueDocumentGeneration == generation, let document = self.queueDocument else { return }
      do {
        let image: CGImage
        if let cached = self.cachedFrames[index] { image = cached }
        else { image = try document.frame(at: index); self.cache(image, at: index) }
        guard !token.isCancelled, !documentToken.isCancelled else { return }
        let duration = document.frameDuration(at: index)
        DispatchQueue.main.async { [weak self] in
          guard let self, !self.closed, self.sourceGeneration == generation, self.frameGeneration == request else { return }
          self.framePending = false
          self.frameIndex = index
          self.frameDuration = self.validDuration(duration)
          self.canvas.display(image, resetZoom: false)
          self.updateControls()
          if self.isAnimating { self.scheduleFrame() }
        }
      } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self, !self.closed, self.sourceGeneration == generation, self.frameGeneration == request else { return }
          self.framePending = false
          self.stopAnimation()
          self.statusLabel.stringValue = "帧读取失败：\(error.localizedDescription)"
          self.updateControls()
        }
      }
    }
  }

  private func validDuration(_ duration: TimeInterval) -> TimeInterval {
    duration.isFinite && duration > 0 ? max(duration, 0.001) : 0.1
  }
  private func startAnimation() {
    guard let details, details.isAnimated, !closed else { return }
    if window?.isMiniaturized == true { wasAnimatingBeforeMiniaturize = true; return }
    let shouldReplay = details.loopCount > 0 && completedLoops >= details.loopCount
    isAnimating = true
    if shouldReplay { completedLoops = 0; requestFrame(0) }
    else if !framePending { scheduleFrame() }
    updateControls()
  }
  private func stopAnimation() {
    timer?.invalidate()
    timer = nil
    animationDeadline = nil
    if isAnimating && framePending {
      frameToken.cancel()
      frameGeneration = UUID()
      framePending = false
    }
    isAnimating = false
    updateControls()
  }
  private func scheduleFrame() {
    timer?.invalidate()
    guard isAnimating, !closed else { return }
    // Advance a monotonic deadline instead of adding decoding time to every frame.
    // Bound catch-up after a system stall so it cannot flood the main run loop.
    let now = CACurrentMediaTime()
    animationDeadline = max((animationDeadline ?? now) + frameDuration, now - 0.25)
    let timer = Timer(timeInterval: max((animationDeadline ?? now) - now, 0.001), repeats: false) { [weak self] _ in
      self?.advanceAnimation()
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  private func advanceAnimation() {
    guard isAnimating, !framePending, let details else { return }
    var next = frameIndex + 1
    if next >= details.frameCount {
      completedLoops += 1
      if details.loopCount > 0 && completedLoops >= details.loopCount { stopAnimation(); return }
      next = 0
    }
    requestFrame(next)
  }

  private func updateControls() {
    let index = files.firstIndex { $0.url == selectedURL }
    previousButton.isEnabled = index.map { $0 > 0 } ?? false
    nextButton.isEnabled = index.map { $0 + 1 < files.count } ?? false
    previousFrameButton.isEnabled = details != nil && frameIndex > 0 && !framePending
    nextFrameButton.isEnabled = details.map { frameIndex + 1 < $0.frameCount } == true && !framePending
    animationButton.isEnabled = details?.isAnimated == true
    animationButton.title = isAnimating ? "暂停动图" : "播放动图"
    frameLabel.stringValue = details.map { "\(frameIndex + 1) / \($0.frameCount) \($0.isAnimated ? "帧" : "页")" } ?? ""
    convertButton.isEnabled = details != nil && !isBusy && !formats.isEmpty && !framePending
    formatPicker.isEnabled = !isBusy && !formats.isEmpty
    cancelButton.isHidden = !isBusy
    progressIndicator.isHidden = !isBusy
    revealButton.isHidden = isBusy || lastOutputURL == nil
    viewOutputButton.isHidden = isBusy || lastOutputURL == nil
    slideshowButton.title = slideshow.isRunning ? "暂停幻灯片" : "播放幻灯片"
    slideshowButton.isEnabled = !closed && !isBusy && (slideshow.isRunning || (!isListing && files.count > 1))
    let folder = directoryURL?.lastPathComponent
    folderLabel.stringValue = "\(folder.map { "当前文件夹：\($0)" } ?? "已选图片") · \(isListing ? "读取中…" : "\(files.count) 张")"
    folderLabel.toolTip = directoryURL?.path ?? "仅浏览显式选择的图片；打开单张图片会自动列出同目录图片。"
  }

  // Slideshow deadlines are independent of an animated image's per-frame timer.
  @objc private func toggleSlideshow() {
    guard !UpdateWorkAdmission.shared.isBlocked else { return }
    if slideshow.isRunning || wasSlideshowRunningBeforeMiniaturize { stopSlideshow(); return }
    guard !closed, !isBusy, !isListing, files.count > 1, window?.attachedSheet == nil,
          window?.isMiniaturized != true else { return }
    slideshow.start(now: CACurrentMediaTime(), imageIsReady: details != nil && canvas.image != nil)
    updateControls()
    if details == nil && !framePending, let selectedURL { load(selectedURL) }
    else { scheduleSlideshow() }
  }

  private func stopSlideshow() {
    slideshowTimer?.invalidate()
    slideshowTimer = nil
    slideshow.stop()
    wasSlideshowRunningBeforeMiniaturize = false
    updateControls()
  }

  private func scheduleSlideshow() {
    slideshowTimer?.invalidate()
    slideshowTimer = nil
    guard slideshow.isRunning, !closed, !isBusy, window?.isMiniaturized != true else { return }
    guard window?.attachedSheet == nil else { stopSlideshow(); return }
    guard let deadline = slideshow.deadline else { return }
    let generation = sourceGeneration
    let timer = Timer(timeInterval: max(0.001, deadline - CACurrentMediaTime()), repeats: false) { [weak self] _ in
      guard let self, !self.closed, self.sourceGeneration == generation, self.slideshow.isRunning else { return }
      if self.window?.attachedSheet != nil { self.stopSlideshow(); return }
      if self.slideshow.consumeAdvance(now: CACurrentMediaTime()) { self.advanceSlideshow() }
      else { self.scheduleSlideshow() }
    }
    slideshowTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func advanceSlideshow() {
    guard slideshow.isRunning, !closed, !isBusy, window?.isMiniaturized != true else { return }
    guard window?.attachedSheet == nil else { stopSlideshow(); return }
    guard files.count > 1 else { stopSlideshow(); return }
    guard let current = files.firstIndex(where: { $0.url == selectedURL }),
          let next = ImageSlideshowPolicy.nextIndex(current: current, count: files.count,
                                                    loops: loopSlideshowButton.state == .on) else {
      stopSlideshow()
      statusLabel.stringValue = "幻灯片已播放到列表末尾。"
      return
    }
    load(files[next].url)
  }

  private func handleSlideshowFailure(url: URL) {
    guard slideshow.isRunning else { return }
    guard slideshow.recordFailure(of: url, among: files.map(\.url)) else {
      stopSlideshow()
      statusLabel.stringValue = "当前列表中的图片均无法读取，幻灯片已停止。请检查文件或更新系统。"
      return
    }
    statusLabel.stringValue = "无法读取 \(url.lastPathComponent)，即将跳过。"
    let generation = sourceGeneration
    slideshowTimer?.invalidate()
    let timer = Timer(timeInterval: 0.75, repeats: false) { [weak self] _ in
      guard let self, self.sourceGeneration == generation else { return }
      self.advanceSlideshow()
    }
    slideshowTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func setSlideshowInterval(_ value: TimeInterval) {
    guard slideshow.setInterval(value, now: CACurrentMediaTime()) else {
      updateIntervalControls()
      statusLabel.stringValue = "请输入 0.5–120 秒内的有效数字。"
      return
    }
    defaults.set(slideshow.interval, forKey: Self.intervalPreference)
    updateIntervalControls()
    // Failed-image skipping has no slideshow deadline; keep that separate timer.
    if slideshow.deadline != nil { scheduleSlideshow() }
  }

  private func updateIntervalControls() {
    intervalField.stringValue = String(format: "%g", slideshow.interval)
    intervalStepper.doubleValue = slideshow.interval
    intervalSlider.doubleValue = log(slideshow.interval)
    intervalSlider.setAccessibilityValue("\(intervalField.stringValue) 秒")
  }

  @objc private func intervalTextChanged() {
    let text = intervalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    setSlideshowInterval(Double(text.replacingOccurrences(of: ",", with: ".")) ?? .nan)
  }
  @objc private func intervalStepChanged() { setSlideshowInterval(intervalStepper.doubleValue) }
  @objc private func intervalSliderChanged() {
    setSlideshowInterval((exp(intervalSlider.doubleValue) * 2).rounded() / 2)
  }
  @objc private func loopSlideshowChanged() {
    defaults.set(loopSlideshowButton.state == .on, forKey: Self.loopPreference)
  }
  @objc private func toggleImageFullscreen() { window?.toggleFullScreen(nil) }

  private func loadFormats() {
    conversionQueue.async { [weak self] in
      let formats = ImageConversionFormat.available
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.formats = formats
        self.formatPicker.removeAllItems()
        for format in formats { self.formatPicker.addItem(withTitle: format.title) }
        if formats.isEmpty { self.formatPicker.addItem(withTitle: "没有可用编码器") }
        self.updateControls()
      }
    }
  }

  private func navigate(_ offset: Int) {
    guard let index = files.firstIndex(where: { $0.url == selectedURL }), files.indices.contains(index + offset) else { return }
    load(files[index + offset].url)
  }
  @objc private func previousImage() { navigate(-1) }
  @objc private func nextImage() { navigate(1) }
  @objc private func previousFrame() { stopSlideshow(); stopAnimation(); completedLoops = 0; requestFrame(frameIndex - 1) }
  @objc private func nextFrame() { stopSlideshow(); stopAnimation(); completedLoops = 0; requestFrame(frameIndex + 1) }
  @objc private func toggleAnimation() { if isAnimating { stopAnimation() } else { startAnimation() } }
  @objc private func zoomIn() { canvas.setZoom(canvas.zoom * 1.25) }
  @objc private func zoomOut() { canvas.setZoom(canvas.zoom / 1.25) }
  @objc private func fit() { canvas.fitToWindow() }
  @objc private func actualSize() { canvas.actualSize() }

  @objc private func sortChanged() { applySort() }
  @objc private func reverseSort() { ascending.toggle(); directionButton.title = ascending ? "↑" : "↓"; applySort() }
  private func applySort() {
    sortRequested = true
    let keys: [PlaylistFileSortKey] = [.name, .size, .modified, .created]
    let key = keys[max(0, min(sortPicker.indexOfSelectedItem, keys.count - 1))]
    files = PlaylistFileMetadata.sortedIndices(for: files, by: key, ascending: ascending).map { files[$0] }
    tableView.reloadData()
    selectCurrentRow()
    if files.count < 2 { stopSlideshow() }
    updateControls()
    if slideshow.isRunning && details != nil && canvas.image != nil {
      slideshow.imageDidDisplay(now: CACurrentMediaTime())
      scheduleSlideshow()
    }
  }
  @objc private func refreshList() {
    guard !closed else { return }
    listToken.cancel()
    listToken = ImageCancellationToken()
    listGeneration = UUID()
    let generation = listGeneration
    let urls = files.map(\.url)
    let directory = directoryURL
    let preferredURL = selectedURL
    let token = listToken
    isListing = true
    updateControls()
    listQueue.async { [weak self] in
      guard !token.isCancelled else { return }
      var candidates = urls
      if let directory {
        candidates = ((try? FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? urls).filter {
            !token.isCancelled && ImageFileSupport.isImageURL($0) &&
              ((try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true)
          }
        let preferredIdentity = preferredURL?.standardizedFileURL.resolvingSymlinksInPath()
        var identities = Set<URL>()
        candidates = candidates.compactMap { url in
          guard !token.isCancelled else { return nil }
          let identity = url.standardizedFileURL.resolvingSymlinksInPath()
          guard identities.insert(identity).inserted else { return nil }
          return identity == preferredIdentity ? preferredURL : url
        }
        if let preferredURL, let preferredIdentity, !identities.contains(preferredIdentity) {
          candidates.append(preferredURL)
        }
      }
      let metadata = candidates.compactMap { candidate -> PlaylistFileMetadata? in
        token.isCancelled ? nil : PlaylistFileMetadata.read(from: candidate)
      }
      guard !token.isCancelled else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.closed, self.listGeneration == generation else { return }
        self.isListing = false
        if directory != nil {
          self.files = metadata
          self.applySort()
          return
        }
        let byURL = Dictionary(metadata.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        self.files = self.files.map { byURL[$0.url] ?? $0 }
        if self.sortRequested { self.applySort(); return }
        self.tableView.reloadData()
        self.selectCurrentRow()
        self.updateControls()
      }
    }
  }
  private func selectCurrentRow() {
    selectingRow = true
    defer { selectingRow = false }
    if let index = files.firstIndex(where: { $0.url == selectedURL }) {
      tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      tableView.scrollRowToVisible(index)
    }
  }
  func numberOfRows(in tableView: NSTableView) -> Int { files.count }
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !selectingRow, files.indices.contains(tableView.selectedRow) else { return }
    let url = files[tableView.selectedRow].url
    if url != selectedURL { load(url) }
  }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard files.indices.contains(row) else { return nil }
    let file = files[row]
    let cell = NSTableCellView()
    let name = NSTextField(labelWithString: file.name)
    name.lineBreakMode = .byTruncatingMiddle
    name.font = .systemFont(ofSize: 12, weight: .medium)
    let tags = NSTextField(labelWithString: "")
    tags.font = .systemFont(ofSize: 10)
    tags.lineBreakMode = .byTruncatingTail
    let value = NSMutableAttributedString(string: "")
    let colors: [NSColor] = [.secondaryLabelColor, .systemGray, .systemGreen, .systemPurple,
                             .systemBlue, .systemYellow, .systemRed, .systemOrange]
    for tag in file.tags {
      value.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: colors[tag.colorIndex]]))
      value.append(NSAttributedString(string: "\(tag.name)  ", attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
    }
    if file.tags.isEmpty {
      value.append(NSAttributedString(string: "无 Finder 标签", attributes: [.foregroundColor: NSColor.tertiaryLabelColor]))
    }
    tags.attributedStringValue = value
    let size = file.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "大小未知"
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    let modified = file.modificationDate.map(formatter.string) ?? "未知"
    let created = file.creationDate.map(formatter.string) ?? "未知"
    let showCreated = sortPicker.indexOfSelectedItem == 3
    let metadata = NSTextField(labelWithString: "\(size) · \(showCreated ? "创建" : "修改") \(showCreated ? created : modified)")
    metadata.font = .systemFont(ofSize: 10)
    metadata.textColor = .secondaryLabelColor
    metadata.lineBreakMode = .byTruncatingTail
    let column = stack([name, tags, metadata], vertical: true, spacing: 3)
    cell.addSubview(column)
    cell.textField = name
    cell.toolTip = ([file.name, size, "修改：\(modified)", "创建：\(created)"] + file.tags.map(\.name)).joined(separator: "\n")
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
      column.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
      column.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      name.widthAnchor.constraint(equalTo: column.widthAnchor), tags.widthAnchor.constraint(equalTo: column.widthAnchor),
      metadata.widthAnchor.constraint(equalTo: column.widthAnchor),
    ])
    return cell
  }

  @objc private func confirmConversion() {
    guard !isBusy, let url = selectedURL, let details, formats.indices.contains(formatPicker.indexOfSelectedItem), let window else { return }
    stopSlideshow()
    let format = formats[formatPicker.indexOfSelectedItem]
    let canPreserve = format == .tiff || (details.isAnimated && format.supportsAnimation)
    let currentOnly = details.frameCount > 1 && !canPreserve
    let source = sourceGeneration
    let index = frameIndex
    stopAnimation()
    let alert = NSAlert()
    alert.messageText = "转换为 \(format.title)？"
    var message = "生成新文件到原图同级目录，不覆盖已有文件。"
    if currentOnly { message += "\n此格式不能保留原图的所有\(details.isAnimated ? "动画帧" : "页面")，将仅导出当前第 \(index + 1) \(details.isAnimated ? "帧" : "页")。" }
    if details.isAnimated && format == .tiff { message += "\n所有动画帧将保存为多页静态图片，不再自动播放，原动画时序不会保留。" }
    if details.hasAlpha && !format.supportsAlpha { message += "\n透明区域将填充白色。" }
    message += "\n跨格式可能改变位深、HDR 和色彩。为保护隐私，输出不会保留原图 EXIF / GPS 信息。"
    alert.informativeText = message
    alert.addButton(withTitle: currentOnly ? "仅导出当前帧 / 页" : "转换并另存")
    alert.addButton(withTitle: "取消")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self, !self.closed, self.sourceGeneration == source, response == .alertFirstButtonReturn else { return }
      self.beginConversion(url: url, format: format, frameIndex: currentOnly ? index : nil)
    }
  }

  @objc private func showMediaInfo() {
    NSApp.sendAction(NSSelectorFromString("menuShowMediaInfo:"), to: NSApp.delegate, from: mediaInfoButton)
  }

  func beginConversion(url: URL, format: ImageConversionFormat, frameIndex: Int?) {
    guard !UpdateWorkAdmission.shared.isBlocked else { return }
    guard !isBusy, !closed else { return }
    guard let updateActivity = UpdateWorkAdmission.shared.beginActivity(reason: "busy.images") else { return }
    stopSlideshow()
    let token = ImageCancellationToken()
    conversionToken = token
    lastOutputURL = nil
    conversionGeneration = UUID()
    let generation = conversionGeneration
    isBusy = true
    progressIndicator.doubleValue = 0
    statusLabel.stringValue = "正在转换 \(url.lastPathComponent)…"
    updateControls()
    conversionQueue.async { [weak self] in
      defer { UpdateWorkAdmission.shared.endActivity(updateActivity) }
      do {
        let output = try ImageConverter.convert(url: url, format: format, frameIndex: frameIndex, token: token) { value in
          DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, self.conversionGeneration == generation, value.isFinite else { return }
            self.progressIndicator.doubleValue = min(max(value, 0), 1) * 100
          }
        }
        DispatchQueue.main.async { [weak self] in
          guard let self, !self.closed, self.conversionGeneration == generation else { return }
          self.lastOutputURL = output
          self.finishConversion("已保存：\(output.path)")
        }
      } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self, !self.closed, self.conversionGeneration == generation else { return }
          self.finishConversion(token.isCancelled ? "转换已取消，原图未修改。" : "转换失败：\(error.localizedDescription)")
        }
      }
    }
  }
  private func finishConversion(_ message: String) {
    isBusy = false
    conversionToken = nil
    statusLabel.stringValue = message
    statusLabel.toolTip = message
    updateControls()
  }
  @objc private func cancelConversion() {
    conversionToken?.cancel()
    statusLabel.stringValue = "正在取消转换…"
  }
  @objc private func revealOutput() {
    if let lastOutputURL { NSWorkspace.shared.activateFileViewerSelecting([lastOutputURL]) }
  }
  @objc private func viewOutput() {
    if let lastOutputURL { open(urls: [lastOutputURL]) }
  }
  func cancelAndClose() {
    tearDown()
    window?.close()
  }
  private func tearDown() {
    guard !closed else { return }
    closed = true
    stopSlideshow()
    wasAnimatingBeforeMiniaturize = false
    isListing = false
    stopAnimation()
    sourceGeneration = UUID()
    frameGeneration = UUID()
    listGeneration = UUID()
    conversionGeneration = UUID()
    sourceToken.cancel()
    listToken.cancel()
    frameToken.cancel()
    if let sheet = window?.attachedSheet {
      window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
      sheet.orderOut(nil)
    }
    conversionToken?.cancel()
    conversionToken = nil
    isBusy = false
    canvas.display(nil, resetZoom: true)
    decodeQueue.async { [weak self] in
      self?.queueDocument = nil
      self?.cachedFrames.removeAll()
      self?.cachedOrder.removeAll()
    }
  }
  func windowWillClose(_ notification: Notification) { tearDown() }
  func windowDidMiniaturize(_ notification: Notification) {
    let wasRunning = slideshow.isRunning
    stopSlideshow()
    wasSlideshowRunningBeforeMiniaturize = wasRunning
    wasAnimatingBeforeMiniaturize = isAnimating
    stopAnimation()
  }
  func windowDidDeminiaturize(_ notification: Notification) {
    if wasAnimatingBeforeMiniaturize { startAnimation() }
    wasAnimatingBeforeMiniaturize = false
    if wasSlideshowRunningBeforeMiniaturize {
      wasSlideshowRunningBeforeMiniaturize = false
      slideshow.start(now: CACurrentMediaTime(), imageIsReady: details != nil && canvas.image != nil)
      if details == nil && !framePending, let selectedURL { load(selectedURL) }
      else { scheduleSlideshow() }
      updateControls()
    }
  }
  func windowDidEnterFullScreen(_ notification: Notification) { fullscreenButton.title = "退出全屏" }
  func windowDidExitFullScreen(_ notification: Notification) { fullscreenButton.title = "全屏" }
  func windowDidBecomeKey(_ notification: Notification) { refreshList() }
}
