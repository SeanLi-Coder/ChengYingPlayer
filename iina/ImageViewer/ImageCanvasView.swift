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
  var onDropURLs: (([URL]) -> Void)?
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
    self.image = image
    if resetZoom {
      fitsWindow = true
      imageOffset = .zero
    }
    if fitsWindow { fitToWindow() }
    needsDisplay = true
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
    imageOffset = CGPoint(x: dragOffset.x + point.x - dragOrigin.x,
                          y: dragOffset.y + point.y - dragOrigin.y)
    fitsWindow = false
    needsDisplay = true
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
