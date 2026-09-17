import Cocoa

/// Controls describe source-pixel edits; the canvas remains a scaled preview only.
final class ImageEditingPanel: NSStackView {
  let ratioPicker = NSPopUpButton(frame: .zero, pullsDown: false)
  let rotateLeftButton = NSButton(title: "↶ 左转", target: nil, action: nil)
  let rotateRightButton = NSButton(title: "↷ 右转", target: nil, action: nil)
  let horizontalButton = NSButton(checkboxWithTitle: "水平翻转", target: nil, action: nil)
  let verticalButton = NSButton(checkboxWithTitle: "垂直翻转", target: nil, action: nil)
  let widthField = NSTextField(string: "")
  let heightField = NSTextField(string: "")
  let aspectLock = NSButton(checkboxWithTitle: "保持比例", target: nil, action: nil)
  let resetButton = NSButton(title: "还原全部", target: nil, action: nil)
  let exitButton = NSButton(title: "退出编辑", target: nil, action: nil)
  let selectionLabel = NSTextField(labelWithString: "")
  var onOrientationChanged: ((ImageEditPlan) -> Void)?
  var onRatioChanged: ((CGFloat?) -> Void)?
  var onResetCrop: (() -> Void)?
  var onExit: (() -> Void)?
  private(set) var orientationPlan = ImageEditPlan()
  private var originalSize = NSSize.zero
  private var cropSize = NSSize.zero
  private var customSize = false
  private let cropResetButton = NSButton(title: "最大选区", target: nil, action: nil)
  private let sizeResetButton = NSButton(title: "原选区尺寸", target: nil, action: nil)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    orientation = .vertical
    alignment = .leading
    spacing = 7
    translatesAutoresizingMaskIntoConstraints = false
    ratioPicker.addItems(withTitles: ["自由裁剪", "原图比例", "1:1", "4:3", "16:9", "9:16"])
    ratioPicker.target = self
    ratioPicker.action = #selector(ratioChanged)
    ratioPicker.setAccessibilityLabel("裁剪比例")
    let first = row([NSTextField(labelWithString: "裁剪"), ratioPicker, cropResetButton,
                     selectionLabel, flexibleSpace(), rotateLeftButton, rotateRightButton,
                     horizontalButton, verticalButton])
    aspectLock.state = .on
    aspectLock.target = self
    aspectLock.action = #selector(lockChanged)
    for field in [widthField, heightField] {
      field.widthAnchor.constraint(equalToConstant: 70).isActive = true
      field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      field.alignment = .right
      field.target = self
      field.action = #selector(sizeChanged(_:))
      field.delegate = self
    }
    widthField.setAccessibilityLabel("输出宽度，像素")
    heightField.setAccessibilityLabel("输出高度，像素")
    let second = row([NSTextField(labelWithString: "输出像素"), widthField,
                      NSTextField(labelWithString: "×"), heightField, aspectLock,
                      sizeResetButton, flexibleSpace(), resetButton, exitButton])
    let hint = NSTextField(wrappingLabelWithString:
      "拖动拉框 / 调整边角裁剪 · Option + 拖动平移 · 滚轮或双指缩放 · 下方选择格式并另存。切换文件或退出会丢弃未导出的编辑，原图不变。")
    hint.font = .systemFont(ofSize: 10)
    hint.textColor = .secondaryLabelColor
    selectionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    selectionLabel.textColor = .secondaryLabelColor
    for view in [first, second, hint] {
      addArrangedSubview(view)
      view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    for button in [rotateLeftButton, rotateRightButton, horizontalButton, verticalButton,
                   resetButton, exitButton, cropResetButton, sizeResetButton] {
      button.target = self
      button.controlSize = .small
    }
    for button in [rotateLeftButton, rotateRightButton, resetButton, exitButton,
                   cropResetButton, sizeResetButton] { button.bezelStyle = .rounded }
    rotateLeftButton.action = #selector(rotateLeft)
    rotateRightButton.action = #selector(rotateRight)
    horizontalButton.action = #selector(flipsChanged)
    verticalButton.action = #selector(flipsChanged)
    resetButton.action = #selector(resetAll)
    exitButton.action = #selector(exitEditing)
    cropResetButton.action = #selector(resetCrop)
    sizeResetButton.action = #selector(resetSize)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(source: CGImage) {
    originalSize = NSSize(width: source.width, height: source.height)
    resetState()
  }

  private func resetState() {
    orientationPlan = ImageEditPlan()
    orientationPlan.sourceWidth = Int(originalSize.width)
    orientationPlan.sourceHeight = Int(originalSize.height)
    horizontalButton.state = .off
    verticalButton.state = .off
    aspectLock.state = .on
    ratioPicker.selectItem(at: 0)
    customSize = false
    cropSize = originalSize
    selectionLabel.stringValue = "\(Int(originalSize.width)) × \(Int(originalSize.height))"
    updateSizeFields()
  }

  func cropDidChange(_ selection: ImagePixelRect?) {
    guard let selection else { return }
    cropSize = NSSize(width: selection.width, height: selection.height)
    selectionLabel.stringValue = "\(selection.width) × \(selection.height)"
    if !customSize { updateSizeFields() }
    else if aspectLock.state == .on { adjustLockedSize(from: widthField) }
  }

  func makePlan(crop: ImagePixelRect?) throws -> ImageEditPlan {
    guard let crop else { throw ImageProcessingError.invalid("请先选择有效的裁剪区域。") }
    guard let width = pixelValue(widthField), let height = pixelValue(heightField) else {
      throw ImageProcessingError.invalid("输出宽高需要是 1–131072 内的整数像素。")
    }
    var result = orientationPlan
    result.crop = crop
    if width != crop.width || height != crop.height {
      result.outputWidth = width
      result.outputHeight = height
    }
    return result
  }

  func setControlsEnabled(_ enabled: Bool) {
    for control: NSControl in [ratioPicker, rotateLeftButton, rotateRightButton, horizontalButton,
                              verticalButton, widthField, heightField, aspectLock, resetButton,
                              exitButton, cropResetButton, sizeResetButton] {
      control.isEnabled = enabled
    }
  }

  private func pixelValue(_ field: NSTextField) -> Int? {
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.utf8.count <= 6, text.utf8.allSatisfy({ (48...57).contains($0) }),
          let value = Int(text), (1...131_072).contains(value) else { return nil }
    return value
  }

  private func updateSizeFields() {
    widthField.stringValue = String(Int(cropSize.width))
    heightField.stringValue = String(Int(cropSize.height))
  }

  private func adjustLockedSize(from field: NSTextField) {
    guard aspectLock.state == .on, cropSize.width > 0, cropSize.height > 0,
          let value = pixelValue(field) else { return }
    let proposed = field === widthField ? Double(value) * cropSize.height / cropSize.width
                                        : Double(value) * cropSize.width / cropSize.height
    let pairedField = field === widthField ? heightField : widthField
    guard proposed.isFinite, proposed > 0, proposed <= 131_072 else {
      pairedField.stringValue = ""
      return
    }
    pairedField.stringValue = String(max(1, Int(proposed.rounded())))
  }

  @objc private func sizeChanged(_ sender: NSTextField) {
    customSize = true
    adjustLockedSize(from: sender)
  }
  @objc private func lockChanged() { adjustLockedSize(from: widthField) }
  @objc private func resetSize() { customSize = false; updateSizeFields() }
  @objc private func resetCrop() { onResetCrop?() }
  @objc private func exitEditing() { onExit?() }
  @objc private func resetAll() {
    resetState()
    onRatioChanged?(nil)
    onOrientationChanged?(orientationPlan)
  }
  @objc private func rotateLeft() {
    orientationPlan.quarterTurnsClockwise = (orientationPlan.quarterTurnsClockwise + 3) % 4
    exchangeFlipAxes()
    orientationChanged()
  }
  @objc private func rotateRight() {
    orientationPlan.quarterTurnsClockwise = (orientationPlan.quarterTurnsClockwise + 1) % 4
    exchangeFlipAxes()
    orientationChanged()
  }
  private func exchangeFlipAxes() {
    // Rotating the current preview conjugates its post-rotation flips to the other axis.
    let horizontal = orientationPlan.flipHorizontal
    orientationPlan.flipHorizontal = orientationPlan.flipVertical
    orientationPlan.flipVertical = horizontal
    horizontalButton.state = orientationPlan.flipHorizontal ? .on : .off
    verticalButton.state = orientationPlan.flipVertical ? .on : .off
  }
  @objc private func flipsChanged() {
    orientationPlan.flipHorizontal = horizontalButton.state == .on
    orientationPlan.flipVertical = verticalButton.state == .on
    orientationChanged()
  }
  private func orientationChanged() {
    customSize = false
    onOrientationChanged?(orientationPlan)
  }
  @objc private func ratioChanged() {
    customSize = false
    onRatioChanged?(selectedRatio)
  }
  var selectedRatio: CGFloat? {
    switch ratioPicker.indexOfSelectedItem {
    case 1:
      let rotated = orientationPlan.quarterTurnsClockwise % 2 != 0
      return rotated ? originalSize.height / originalSize.width : originalSize.width / originalSize.height
    case 2: return 1
    case 3: return 4.0 / 3.0
    case 4: return 16.0 / 9.0
    case 5: return 9.0 / 16.0
    default: return nil
    }
  }

  private func row(_ views: [NSView]) -> NSStackView {
    let result = NSStackView(views: views)
    result.orientation = .horizontal
    result.alignment = .centerY
    result.spacing = 8
    return result
  }
  private func flexibleSpace() -> NSView {
    let result = NSView()
    result.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return result
  }
}

extension ImageEditingPanel: NSTextFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSTextField, field === widthField || field === heightField else { return }
    sizeChanged(field)
  }
}
