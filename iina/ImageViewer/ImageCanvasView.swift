import Cocoa

/// Pixel dimensions remain independent of AppKit points and monitor scale.
final class ImageCanvasView: NSView {
  private(set) var image: CGImage?
  private(set) var zoom: CGFloat = 1
  private(set) var imageOffset = CGPoint.zero
  private(set) var fitsWindow = true
  var onZoomChanged: ((CGFloat) -> Void)?
  var onNavigate: ((Int) -> Void)?
  var onToggleAnimation: (() -> Void)?
  var onToggleSlideshow: (() -> Void)?
  var onDropURLs: (([URL]) -> Void)?
  var onCropSelectionChanged: ((ImagePixelRect?) -> Void)?
  var cropEnabled = false {
    didSet {
      cropDrag = nil
      cropHasDragged = false
      if cropEnabled && cropSelection == nil { resetCropSelection() }
      updateCropAccessibility()
      window?.invalidateCursorRects(for: self)
      needsDisplay = true
    }
  }
  var cropInteractionEnabled = true {
    didSet {
      guard cropInteractionEnabled != oldValue else { return }
      cropDrag = nil
      cropHasDragged = false
      updateCropAccessibility()
      window?.invalidateCursorRects(for: self)
    }
  }
  var cropAspectRatio: CGFloat? {
    didSet {
      cropAspectRatio = ImageCropGeometry.validAspect(cropAspectRatio)
      if oldValue != cropAspectRatio && cropEnabled { resetCropSelection() }
    }
  }
  var cropSelection: ImagePixelRect? {
    get { storedCropSelection }
    set { updateCropSelection(newValue) }
  }
  private var storedCropSelection: ImagePixelRect?
  private enum CropDrag {
    case create(CGPoint)
    case move(ImagePixelRect, CGPoint)
    case resize(ImagePixelRect, ImageCropGeometry.Handle)
    case pan
  }
  private var cropDrag: CropDrag?
  private var cropHasDragged = false
  private var dragOrigin = CGPoint.zero
  private var dragOffset = CGPoint.zero
  private var previousBackingScale: CGFloat = 1

  override var acceptsFirstResponder: Bool { true }
  var backingScale: CGFloat { max(window?.backingScaleFactor ?? 1, 1) }
  var imageRect: CGRect {
    guard let image else { return .zero }
    let size = CGSize(width: CGFloat(image.width) * zoom / backingScale,
                      height: CGFloat(image.height) * zoom / backingScale)
    return CGRect(x: bounds.midX + imageOffset.x - size.width / 2,
                  y: bounds.midY + imageOffset.y - size.height / 2,
                  width: size.width, height: size.height)
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityRole(.image)
    setAccessibilityLabel("图片画布")
    registerForDraggedTypes([.fileURL])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func display(_ image: CGImage?, resetZoom: Bool) {
    let dimensionsChanged = self.image?.width != image?.width || self.image?.height != image?.height
    self.image = image
    if resetZoom || dimensionsChanged {
      cropDrag = nil
      if cropEnabled { resetCropSelection() } else { updateCropSelection(nil) }
    }
    if resetZoom {
      fitsWindow = true
      imageOffset = .zero
    }
    if fitsWindow { fitToWindow() }
    needsDisplay = true
  }

  func resetCropSelection() {
    guard let image else { updateCropSelection(nil); return }
    cropDrag = nil
    updateCropSelection(ImageCropGeometry.largest(width: image.width, height: image.height, aspect: cropAspectRatio))
  }

  private func updateCropSelection(_ proposed: ImagePixelRect?) {
    let next = image.flatMap { ImageCropGeometry.sanitize(proposed, width: $0.width, height: $0.height) }
    guard next != storedCropSelection else { return }
    storedCropSelection = next
    updateCropAccessibility()
    needsDisplay = true
    window?.invalidateCursorRects(for: self)
    onCropSelectionChanged?(next)
  }

  private func updateCropAccessibility() {
    setAccessibilityLabel(cropEnabled ? "图片裁剪画布" : "图片画布")
    toolTip = !cropEnabled ? nil : cropInteractionEnabled
      ? "拖动边角调整裁剪，拖动选区移动；Shift 拖动重新选区，Option 拖动平移图片。"
      : "正在处理图片，裁剪选区暂时锁定；仍可缩放查看。"
    setAccessibilityHelp(cropEnabled ? toolTip : nil)
    if cropEnabled, let rect = cropSelection {
      setAccessibilityValue("起点 \(rect.x)、\(rect.y)，宽 \(rect.width) 像素，高 \(rect.height) 像素")
    } else {
      setAccessibilityValue(nil)
    }
  }

  var cropRectInView: CGRect? {
    guard let image, let cropSelection else { return nil }
    return ImageCropGeometry.viewRect(cropSelection, imageRect: imageRect, width: image.width, height: image.height)
  }

  private func sourcePoint(_ point: CGPoint) -> CGPoint? {
    guard let image else { return nil }
    return ImageCropGeometry.sourcePoint(point, imageRect: imageRect, width: image.width, height: image.height)
  }

  func fitToWindow() {
    fitsWindow = true
    imageOffset = .zero
    if let image, bounds.width > 0, bounds.height > 0 {
      zoom = min((max(bounds.width - 32, 1) * backingScale) / CGFloat(image.width),
                 (max(bounds.height - 32, 1) * backingScale) / CGFloat(image.height))
      zoom = max(min(zoom, 64), 0.0001)
    }
    needsDisplay = true
    onZoomChanged?(zoom)
  }

  func actualSize() { setZoom(1, anchor: CGPoint(x: bounds.midX, y: bounds.midY)) }

  func setZoom(_ proposed: CGFloat, anchor: CGPoint? = nil) {
    guard image != nil, proposed.isFinite, proposed > 0, zoom.isFinite, zoom > 0 else { return }
    let next = min(max(proposed, 0.0001), 64)
    let point = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
    guard point.x.isFinite, point.y.isFinite else { return }
    let centered = CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
    let ratio = next / zoom
    let nextOffset = CGPoint(x: centered.x + (imageOffset.x - centered.x) * ratio,
                             y: centered.y + (imageOffset.y - centered.y) * ratio)
    guard nextOffset.x.isFinite, nextOffset.y.isFinite else { return }
    imageOffset = nextOffset
    zoom = next
    fitsWindow = false
    needsDisplay = true
    onZoomChanged?(zoom)
  }

  override func layout() {
    super.layout()
    if fitsWindow { fitToWindow() }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    previousBackingScale = backingScale
    if fitsWindow { fitToWindow() }
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    if fitsWindow {
      fitToWindow()
    } else {
      let ratio = previousBackingScale / backingScale
      imageOffset.x *= ratio
      imageOffset.y *= ratio
      needsDisplay = true
    }
    previousBackingScale = backingScale
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
    guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
    let rect = imageRect
    guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else { return }
    context.saveGState()
    context.clip(to: rect.intersection(bounds))
    let tile: CGFloat = 14
    let visible = rect.intersection(bounds)
    if !visible.isNull {
      NSColor(white: 0.22, alpha: 1).setFill()
      visible.fill()
      NSColor(white: 0.28, alpha: 1).setFill()
      let minX = Int(floor(visible.minX / tile))
      let minY = Int(floor(visible.minY / tile))
      let maxX = Int(ceil(visible.maxX / tile))
      let maxY = Int(ceil(visible.maxY / tile))
      for y in minY..<maxY {
        for x in minX..<maxX where (x + y) % 2 == 0 {
          CGRect(x: CGFloat(x) * tile, y: CGFloat(y) * tile, width: tile, height: tile).fill()
        }
      }
    }
    context.interpolationQuality = zoom >= 8 ? .none : .high
    context.draw(image, in: rect)
    context.restoreGState()
    if cropEnabled { drawCropOverlay(in: context) }
  }

  private func drawCropOverlay(in context: CGContext) {
    guard let selection = cropSelection, let cropRect = cropRectInView else { return }
    let visible = imageRect.intersection(bounds)
    guard !visible.isNull, !visible.isEmpty else { return }
    context.saveGState()
    context.clip(to: visible)
    let mask = NSBezierPath(rect: imageRect)
    mask.appendRect(cropRect)
    mask.windingRule = .evenOdd
    NSColor.black.withAlphaComponent(0.52).setFill()
    mask.fill()
    NSColor.white.withAlphaComponent(0.38).setStroke()
    let grid = NSBezierPath()
    for fraction in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
      grid.move(to: CGPoint(x: cropRect.minX + cropRect.width * fraction, y: cropRect.minY))
      grid.line(to: CGPoint(x: cropRect.minX + cropRect.width * fraction, y: cropRect.maxY))
      grid.move(to: CGPoint(x: cropRect.minX, y: cropRect.minY + cropRect.height * fraction))
      grid.line(to: CGPoint(x: cropRect.maxX, y: cropRect.minY + cropRect.height * fraction))
    }
    grid.lineWidth = 1
    grid.stroke()
    NSColor.black.withAlphaComponent(0.8).setStroke()
    let border = NSBezierPath(rect: cropRect)
    border.lineWidth = 3
    border.stroke()
    NSColor.white.setStroke()
    border.lineWidth = 1
    border.stroke()
    for handle in ImageCropGeometry.Handle.allCases {
      let point = handlePoint(handle, rect: cropRect)
      let handleRect = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
      NSColor.white.setFill()
      handleRect.fill()
      NSColor.black.withAlphaComponent(0.8).setStroke()
      NSBezierPath(rect: handleRect).stroke()
    }
    context.restoreGState()

    let text = "\(selection.width) × \(selection.height) 像素" as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                   .foregroundColor: NSColor.white]
    let size = text.size(withAttributes: attributes)
    let label = CGRect(x: min(max(cropRect.midX - (size.width + 16) / 2, bounds.minX + 4), max(bounds.minX + 4, bounds.maxX - size.width - 20)),
                       y: min(max(cropRect.maxY + 7, bounds.minY + 4), max(bounds.minY + 4, bounds.maxY - size.height - 12)),
                       width: size.width + 16, height: size.height + 8)
    NSColor.black.withAlphaComponent(0.8).setFill()
    NSBezierPath(roundedRect: label, xRadius: 5, yRadius: 5).fill()
    text.draw(at: CGPoint(x: label.minX + 8, y: label.minY + 4), withAttributes: attributes)
  }

  private func handlePoint(_ handle: ImageCropGeometry.Handle, rect: CGRect) -> CGPoint {
    CGPoint(x: handle.horizontal < 0 ? rect.minX : handle.horizontal > 0 ? rect.maxX : rect.midX,
            y: handle.vertical < 0 ? rect.maxY : handle.vertical > 0 ? rect.minY : rect.midY)
  }

  private func cropHandle(at point: CGPoint) -> ImageCropGeometry.Handle? {
    guard let rect = cropRectInView else { return nil }
    return ImageCropGeometry.Handle.allCases.filter {
      let p = handlePoint($0, rect: rect)
      return abs(point.x - p.x) <= 8 && abs(point.y - p.y) <= 8
    }.min {
      let a = handlePoint($0, rect: rect), b = handlePoint($1, rect: rect)
      return hypot(point.x - a.x, point.y - a.y) < hypot(point.x - b.x, point.y - b.y)
    }
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    guard cropEnabled else { return }
    guard cropInteractionEnabled else { addCursorRect(bounds, cursor: .arrow); return }
    addCursorRect(bounds, cursor: .crosshair)
    guard let rect = cropRectInView else { return }
    let visible = rect.intersection(bounds)
    if let image, let cropSelection,
       cropSelection.width != image.width || cropSelection.height != image.height,
       !visible.isNull, !visible.isEmpty { addCursorRect(visible, cursor: .openHand) }
    for handle in ImageCropGeometry.Handle.allCases {
      let point = handlePoint(handle, rect: rect)
      let target = CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16).intersection(bounds)
      guard !target.isNull, !target.isEmpty else { continue }
      addCursorRect(target, cursor: handle.horizontal == 0 ? .resizeUpDown : handle.vertical == 0 ? .resizeLeftRight : .crosshair)
    }
  }

  override func magnify(with event: NSEvent) {
    setZoom(zoom * max(1 + event.magnification, 0.01),
            anchor: convert(event.locationInWindow, from: nil))
  }

  override func scrollWheel(with event: NSEvent) {
    let delta = event.scrollingDeltaY
    if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas {
      guard delta.isFinite, delta != 0 else { return }
      setZoom(zoom * exp(min(max(delta * 0.02, -1), 1)),
              anchor: convert(event.locationInWindow, from: nil))
    } else {
      guard event.scrollingDeltaX.isFinite, delta.isFinite else { return }
      imageOffset.x += event.scrollingDeltaX
      imageOffset.y -= delta
      fitsWindow = false
      needsDisplay = true
    }
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    if cropEnabled {
      guard cropInteractionEnabled else { return }
      beginCropDrag(with: event)
      return
    }
    if event.clickCount == 2 {
      if fitsWindow { actualSize() } else { fitToWindow() }
      return
    }
    dragOrigin = convert(event.locationInWindow, from: nil)
    dragOffset = imageOffset
  }

  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard point.x.isFinite, point.y.isFinite else { return }
    if cropEnabled {
      guard cropInteractionEnabled else { return }
      cropHasDragged = true
      updateCropDrag(at: point)
      return
    }
    imageOffset = CGPoint(x: dragOffset.x + point.x - dragOrigin.x,
                          y: dragOffset.y + point.y - dragOrigin.y)
    fitsWindow = false
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    if cropEnabled {
      if cropInteractionEnabled && cropHasDragged { updateCropDrag(at: convert(event.locationInWindow, from: nil)) }
      cropDrag = nil
      cropHasDragged = false
    } else {
      super.mouseUp(with: event)
    }
  }

  private func beginCropDrag(with event: NSEvent) {
    cropDrag = nil
    cropHasDragged = false
    let point = convert(event.locationInWindow, from: nil)
    guard point.x.isFinite, point.y.isFinite else { return }
    if event.modifierFlags.contains(.option) {
      cropDrag = .pan
      dragOrigin = point
      dragOffset = imageOffset
      return
    }
    guard let image, let source = sourcePoint(point) else { return }
    if !event.modifierFlags.contains(.shift), let selection = cropSelection {
      if let handle = cropHandle(at: point) {
        cropDrag = .resize(selection, handle)
        return
      }
      guard imageRect.contains(point) else { return }
      let isFullImage = selection.x == 0 && selection.y == 0 && selection.width == image.width && selection.height == image.height
      if !isFullImage, cropRectInView?.contains(point) == true {
        cropDrag = .move(selection, source)
        return
      }
    }
    guard imageRect.contains(point) else { return }
    cropDrag = .create(source)
  }

  private func updateCropDrag(at point: CGPoint) {
    guard let image, let cropDrag else { return }
    if case .pan = cropDrag {
      let next = CGPoint(x: dragOffset.x + point.x - dragOrigin.x, y: dragOffset.y + point.y - dragOrigin.y)
      guard next.x.isFinite, next.y.isFinite else { return }
      imageOffset = next
      fitsWindow = false
      needsDisplay = true
      window?.invalidateCursorRects(for: self)
      return
    }
    guard let source = sourcePoint(point) else { return }
    switch cropDrag {
    case .create(let start):
      updateCropSelection(ImageCropGeometry.create(from: start, to: source, width: image.width, height: image.height, aspect: cropAspectRatio))
    case .move(let selection, let start):
      updateCropSelection(ImageCropGeometry.move(selection, delta: CGPoint(x: source.x - start.x, y: source.y - start.y), width: image.width, height: image.height))
    case .resize(let selection, let handle):
      updateCropSelection(ImageCropGeometry.resize(selection, handle: handle, to: source, width: image.width, height: image.height, aspect: cropAspectRatio))
    case .pan: break
    }
  }

  override func keyDown(with event: NSEvent) {
    guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
      super.keyDown(with: event)
      return
    }
    switch event.keyCode {
    case 123: onNavigate?(-1)
    case 124: onNavigate?(1)
    case 49: onToggleAnimation?()
    default:
      switch event.charactersIgnoringModifiers {
      case "+", "=": setZoom(zoom * 1.25)
      case "-": setZoom(zoom / 1.25)
      case "0": fitToWindow()
      case "1": actualSize()
      case "s", "S": onToggleSlideshow?()
      default: super.keyDown(with: event)
      }
    }
  }

  static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
    (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    onDropURLs != nil && !Self.fileURLs(from: sender.draggingPasteboard).isEmpty ? .copy : []
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let urls = Self.fileURLs(from: sender.draggingPasteboard)
    guard !urls.isEmpty, let onDropURLs else { return false }
    onDropURLs(urls)
    return true
  }
}
