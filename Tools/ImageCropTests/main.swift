import Cocoa

NSApplication.shared.setActivationPolicy(.prohibited)
setbuf(stdout, nil)
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}
func close(_ first: CGFloat, _ second: CGFloat) -> Bool { abs(first - second) < 0.00001 }
func bounded(_ rect: ImagePixelRect?, width: Int = 400, height: Int = 300) -> Bool {
  guard let rect else { return false }
  return rect.x >= 0 && rect.y >= 0 && rect.x < width && rect.y < height && rect.width > 0 && rect.height > 0 &&
    rect.width <= width - rect.x && rect.height <= height - rect.y
}

let full = ImagePixelRect(x: 0, y: 0, width: 400, height: 300)
check(ImageCropGeometry.largest(width: 400, height: 300, aspect: nil) == full, "Free crop begins at the exact full source extent")
check(ImageCropGeometry.largest(width: 400, height: 300, aspect: 1) == ImagePixelRect(x: 50, y: 0, width: 300, height: 300),
      "A square selection is the largest centered inscribed rectangle")
check(ImageCropGeometry.largest(width: 400, height: 300, aspect: 4 / 3) == full, "The original aspect preserves all pixels")
check(ImageCropGeometry.largest(width: 400, height: 300, aspect: .nan) == full, "Non-finite aspect ratios safely fall back to free crop")
check(ImageCropGeometry.largest(width: 0, height: 300, aspect: nil) == nil, "Missing image dimensions cannot produce a selection")
check(ImageCropGeometry.sanitize(ImagePixelRect(x: Int.max, y: Int.min, width: Int.max, height: Int.max), width: 400, height: 300)
      == ImagePixelRect(x: 399, y: 0, width: 1, height: 300), "Untrusted integer bounds cannot overflow crop validation")
check(ImageCropGeometry.sanitize(ImagePixelRect(x: 0, y: 0, width: -1, height: 2), width: 400, height: 300) == nil,
      "Nonpositive pixel dimensions are rejected")
check(ImageCropGeometry.largest(width: Int.max, height: 1, aspect: CGFloat.greatestFiniteMagnitude)?.width == Int.max,
      "The floating-point representation of Int.max never traps integer conversion")

let sample = ImagePixelRect(x: 53, y: 27, width: 81, height: 66)
for backingScale in [CGFloat(1), 2] {
  for zoom in [CGFloat(0.0001), 0.5, 1, 2, 64] {
    for offset in [CGPoint.zero, CGPoint(x: -142, y: 71)] {
      let display = CGRect(x: 350 + offset.x - 200 * zoom / backingScale,
                           y: 250 + offset.y - 150 * zoom / backingScale,
                           width: 400 * zoom / backingScale, height: 300 * zoom / backingScale)
      let view = ImageCropGeometry.viewRect(sample, imageRect: display, width: 400, height: 300)
      let start = ImageCropGeometry.sourcePoint(CGPoint(x: view.minX, y: view.maxY), imageRect: display, width: 400, height: 300)!
      let end = ImageCropGeometry.sourcePoint(CGPoint(x: view.maxX, y: view.minY), imageRect: display, width: 400, height: 300)!
      check(close(start.x, 53) && close(start.y, 27) && close(end.x, 134) && close(end.y, 93),
            "Source pixel edges round-trip at scale \(backingScale), zoom \(zoom), and offset \(offset)")
    }
  }
}
check(ImageCropGeometry.sourcePoint(CGPoint(x: CGFloat.infinity, y: 0), imageRect: CGRect(x: 0, y: 0, width: 400, height: 300), width: 400, height: 300) == nil,
      "Non-finite pointer coordinates never reach integer conversion")
check(ImageCropGeometry.sourcePoint(.zero, imageRect: .zero, width: 400, height: 300) == nil,
      "An empty rendering rectangle cannot produce crop coordinates")
check(ImageCropGeometry.create(from: CGPoint(x: 400, y: 300), to: .zero, width: 400, height: 300, aspect: nil) == full,
      "Reverse dragging from the last image edge includes every source pixel")
check(ImageCropGeometry.create(from: CGPoint(x: 399, y: 299), to: CGPoint(x: 399, y: 299), width: 400, height: 300, aspect: nil)
      == ImagePixelRect(x: 399, y: 299, width: 1, height: 1), "A zero-distance drag is bounded to one pixel")

var generator: UInt64 = 0x43524F5050494E47
func random(_ upper: Int) -> Int {
  generator = generator &* 6364136223846793005 &+ 1442695040888963407
  return Int((generator >> 33) % UInt64(upper))
}
let testRatios: [CGFloat?] = [nil, 1, 4 / 3, 16 / 9, 9 / 16, 0.0000001, 100_000_000]
for ratio in testRatios {
  var allBounded = true
  for _ in 0..<200 {
    let start = CGPoint(x: random(800) - 200, y: random(600) - 150)
    let end = CGPoint(x: random(800) - 200, y: random(600) - 150)
    let created = ImageCropGeometry.create(from: start, to: end, width: 400, height: 300, aspect: ratio)!
    allBounded = allBounded && bounded(created)
    for handle in ImageCropGeometry.Handle.allCases {
      allBounded = allBounded && bounded(ImageCropGeometry.resize(created, handle: handle, to: end, width: 400, height: 300, aspect: ratio))
    }
    allBounded = allBounded && bounded(ImageCropGeometry.move(created, delta: end, width: 400, height: 300))
  }
  check(allBounded, "Creation, eight resize handles, and movement remain in bounds for aspect \(String(describing: ratio))")
}
let initial = ImagePixelRect(x: 100, y: 80, width: 120, height: 100)
for handle in ImageCropGeometry.Handle.allCases {
  let resized = ImageCropGeometry.resize(initial, handle: handle, to: CGPoint(x: 240, y: 220), width: 400, height: 300, aspect: nil)!
  check(handle.horizontal >= 0 || resized.x + resized.width == initial.x + initial.width, "A left resize keeps the opposite source edge fixed")
  check(handle.horizontal <= 0 || resized.x == initial.x, "A right resize keeps the opposite source edge fixed")
  check(handle.vertical >= 0 || resized.y + resized.height == initial.y + initial.height, "A top resize keeps the opposite source edge fixed")
  check(handle.vertical <= 0 || resized.y == initial.y, "A bottom resize keeps the opposite source edge fixed")
}
for aspect: CGFloat in [1, 4 / 3, 16 / 9, 9 / 16] {
  for handle in ImageCropGeometry.Handle.allCases {
    let resized = ImageCropGeometry.resize(initial, handle: handle, to: CGPoint(x: 320, y: 210), width: 400, height: 300, aspect: aspect)!
    check(abs(CGFloat(resized.width) - CGFloat(resized.height) * aspect) <= max(1, aspect),
          "Fixed-aspect resize has at most one source-pixel quantization error")
  }
}

func makeImage(width: Int, height: Int) -> CGImage {
  var data = Data(count: width * height * 4)
  data.withUnsafeMutableBytes { raw in
    let bytes = raw.bindMemory(to: UInt8.self)
    for y in 0..<height {
      for x in 0..<width {
        let p = (y * width + x) * 4
        bytes[p] = UInt8(x % 256); bytes[p + 1] = UInt8(y % 256)
        bytes[p + 2] = UInt8(((x / 25 + y / 25) % 2) * 120 + 60); bytes[p + 3] = 255
      }
    }
  }
  return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                 provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}
let canvas = ImageCanvasView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
let window = NSWindow(contentRect: canvas.bounds, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.contentView = canvas
window.orderFront(nil)
defer { window.close() }
let source = makeImage(width: 400, height: 300)
canvas.display(source, resetZoom: true)
var selectionChanges: [ImagePixelRect?] = []
canvas.onCropSelectionChanged = { selectionChanges.append($0) }
canvas.cropEnabled = true
check(canvas.cropSelection == full && selectionChanges.last! == full, "Enabling native crop selects the full image and notifies the owner")
func viewPoint(_ source: CGPoint) -> CGPoint {
  CGPoint(x: canvas.imageRect.minX + source.x / 400 * canvas.imageRect.width,
          y: canvas.imageRect.maxY - source.y / 300 * canvas.imageRect.height)
}
func mouse(_ type: NSEvent.EventType, _ point: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
  NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
}
func drag(_ start: CGPoint, _ end: CGPoint, flags: NSEvent.ModifierFlags = []) {
  canvas.mouseDown(with: mouse(.leftMouseDown, start, flags: flags))
  canvas.mouseDragged(with: mouse(.leftMouseDragged, end, flags: flags))
  canvas.mouseUp(with: mouse(.leftMouseUp, end, flags: flags))
}
drag(viewPoint(CGPoint(x: 50, y: 40)), viewPoint(CGPoint(x: 200, y: 160)))
check(canvas.cropSelection == ImagePixelRect(x: 50, y: 40, width: 150, height: 120), "Real mouse events create top-left source pixel coordinates")
drag(viewPoint(CGPoint(x: 125, y: 100)), viewPoint(CGPoint(x: 180, y: 150)))
check(canvas.cropSelection == ImagePixelRect(x: 105, y: 90, width: 150, height: 120), "Dragging the native selection interior moves without resizing")
drag(viewPoint(CGPoint(x: 105, y: 150)), viewPoint(CGPoint(x: 75, y: 150)))
check(canvas.cropSelection == ImagePixelRect(x: 75, y: 90, width: 180, height: 120), "The left edge handle resizes in source pixels")
drag(viewPoint(CGPoint(x: 255, y: 210)), viewPoint(CGPoint(x: 300, y: 250)))
check(canvas.cropSelection == ImagePixelRect(x: 75, y: 90, width: 225, height: 160), "The bottom-right corner resizes both source dimensions")
let resizedWithMouse = canvas.cropSelection
for handle in ImageCropGeometry.Handle.allCases {
  canvas.cropSelection = initial
  let start = CGPoint(x: handle.horizontal < 0 ? 100 : handle.horizontal > 0 ? 220 : 160,
                      y: handle.vertical < 0 ? 80 : handle.vertical > 0 ? 180 : 130)
  let end = CGPoint(x: start.x + 20, y: start.y + 15)
  drag(viewPoint(start), viewPoint(end))
  check(canvas.cropSelection == ImageCropGeometry.resize(initial, handle: handle, to: end, width: 400, height: 300, aspect: nil),
        "Native pointer hit testing routes the \(handle) handle to the correct source resize")
}
canvas.cropSelection = full
drag(viewPoint(CGPoint(x: 400, y: 150)), viewPoint(CGPoint(x: 350, y: 150)))
check(canvas.cropSelection == ImagePixelRect(x: 0, y: 0, width: 350, height: 300),
      "A handle on the exclusive outer image edge remains draggable")
canvas.cropSelection = resizedWithMouse
let preserved = canvas.cropSelection
let originalOffset = canvas.imageOffset
drag(CGPoint(x: 350, y: 250), CGPoint(x: 391, y: 227), flags: .option)
check(canvas.cropSelection == preserved && canvas.imageOffset == CGPoint(x: originalOffset.x + 41, y: originalOffset.y - 23),
      "Option dragging pans the image without editing the selection")
canvas.setZoom(canvas.zoom * 1.3, anchor: CGPoint(x: 270, y: 210))
drag(viewPoint(CGPoint(x: 91, y: 77)), viewPoint(CGPoint(x: 230, y: 189)), flags: .shift)
check(canvas.cropSelection == ImagePixelRect(x: 91, y: 77, width: 139, height: 112),
      "After anchored zoom and pan, native pointer dragging still yields exact source pixels")
let zoomedSelection = canvas.cropSelection
canvas.setZoom(canvas.zoom * 0.8)
check(canvas.cropSelection == zoomedSelection, "Changing zoom never resamples or shifts the source selection")
let lockedSelection = canvas.cropSelection
let lockedCallbacks = selectionChanges.count
canvas.mouseDown(with: mouse(.leftMouseDown, viewPoint(CGPoint(x: 91, y: 77))))
canvas.cropInteractionEnabled = false
canvas.mouseDragged(with: mouse(.leftMouseDragged, viewPoint(CGPoint(x: 51, y: 47))))
canvas.mouseUp(with: mouse(.leftMouseUp, viewPoint(CGPoint(x: 51, y: 47))))
check(canvas.cropSelection == lockedSelection && selectionChanges.count == lockedCallbacks,
      "Locking between mouse-down and mouse-drag cancels the in-flight crop without callbacks")
drag(viewPoint(CGPoint(x: 20, y: 20)), viewPoint(CGPoint(x: 290, y: 200)), flags: .shift)
check(canvas.cropSelection == lockedSelection && selectionChanges.count == lockedCallbacks,
      "A locked crop ignores new mouse selection gestures and never changes output dimensions")
let lockedZoom = canvas.zoom
canvas.setZoom(lockedZoom * 1.1)
check(canvas.cropEnabled && canvas.cropRectInView != nil && canvas.zoom > lockedZoom && canvas.cropSelection == lockedSelection,
      "Locked editing keeps the overlay and permits zooming without changing source crop pixels")
check(canvas.accessibilityHelp()?.contains("锁定") == true, "The locked canvas announces its temporary interaction state")
canvas.cropInteractionEnabled = true
canvas.mouseDragged(with: mouse(.leftMouseDragged, viewPoint(CGPoint(x: 51, y: 47))))
canvas.mouseUp(with: mouse(.leftMouseUp, viewPoint(CGPoint(x: 51, y: 47))))
check(canvas.cropSelection == lockedSelection && selectionChanges.count == lockedCallbacks,
      "Unlocking does not revive a cancelled pointer drag")
canvas.mouseDown(with: mouse(.leftMouseDown, viewPoint(CGPoint(x: 91, y: 77))))
canvas.mouseDragged(with: mouse(.leftMouseDragged, viewPoint(CGPoint(x: 85, y: 72))))
let changedBeforeLock = canvas.cropSelection
let callbacksBeforeLock = selectionChanges.count
canvas.cropInteractionEnabled = false
canvas.mouseUp(with: mouse(.leftMouseUp, viewPoint(CGPoint(x: 40, y: 40))))
check(canvas.cropSelection == changedBeforeLock && selectionChanges.count == callbacksBeforeLock,
      "Locking after a partial drag prevents the final mouse-up from committing a different crop")
canvas.cropInteractionEnabled = true
canvas.cropAspectRatio = 16 / 9
check(canvas.cropSelection == ImageCropGeometry.largest(width: 400, height: 300, aspect: 16 / 9),
      "The owner's aspect control resets to the largest valid inscribed crop")
drag(viewPoint(CGPoint(x: 40, y: 40)), viewPoint(CGPoint(x: 240, y: 140)), flags: .shift)
check(abs(CGFloat(canvas.cropSelection!.width) / CGFloat(canvas.cropSelection!.height) - 16 / 9) < 0.02,
      "Real fixed-aspect dragging preserves the requested ratio to pixel precision")
check((canvas.accessibilityValue() as? String)?.contains("像素") == true && canvas.accessibilityHelp()?.contains("Option") == true,
      "Assistive technology receives source dimensions and the alternate pan gesture")

if let capture = ProcessInfo.processInfo.environment["CHENGYING_CAPTURE_DIR"] {
  let directory = URL(fileURLWithPath: capture)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    window.appearance = NSAppearance(named: appearance)
    canvas.needsDisplay = true
    window.displayIfNeeded()
    window.effectiveAppearance.performAsCurrentDrawingAppearance {
      let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
      canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
      let file = directory.appendingPathComponent("crop-\(appearance.rawValue).png")
      try! bitmap.representation(using: .png, properties: [:])!.write(to: file)
      print("SNAPSHOT: \(file.path)")
    }
  }
}

canvas.cropAspectRatio = nil
canvas.cropSelection = ImagePixelRect(x: 10, y: 20, width: 80, height: 60)
let rendered = try ImageEditor.render(source, plan: ImageEditPlan(crop: canvas.cropSelection, sourceWidth: 400, sourceHeight: 300))
check(rendered.width == 80 && rendered.height == 60, "The real image-editing backend accepts the canvas's integer source rectangle")
let pixels = CGContext(data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8,
                       bytesPerRow: rendered.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
pixels.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
let rgba = pixels.data!.assumingMemoryBound(to: UInt8.self)
check(rgba[0] == 10 && rgba[1] == 20 && rgba[((60 - 1) * 80 + 79) * 4] == 89 && rgba[((60 - 1) * 80 + 79) * 4 + 1] == 79,
      "Real exported corner pixels match the selected top-left source range, without a vertical flip")
let cropBeforeFrame = canvas.cropSelection
canvas.display(makeImage(width: 400, height: 300), resetZoom: false)
check(canvas.cropSelection == cropBeforeFrame, "Same-size animation frames preserve the current pixel selection")
canvas.display(makeImage(width: 70, height: 30), resetZoom: false)
check(canvas.cropSelection == ImagePixelRect(x: 0, y: 0, width: 70, height: 30), "A frame dimension change replaces any out-of-bounds crop")
canvas.display(source, resetZoom: true)
check(canvas.fitsWindow && canvas.imageOffset == .zero && canvas.cropSelection == full,
      "A new source preserves resetZoom semantics and resets stale crop coordinates")
canvas.cropSelection = ImagePixelRect(x: Int.max, y: Int.max, width: Int.max, height: Int.max)
check(canvas.cropSelection == ImagePixelRect(x: 399, y: 299, width: 1, height: 1), "Public selection assignment cannot store unsafe integer extents")
canvas.cropAspectRatio = .infinity
check(canvas.cropAspectRatio == nil, "The canvas rejects non-finite aspect configuration")
canvas.cropEnabled = false
let disabledCrop = canvas.cropSelection
let previousOffset = canvas.imageOffset
drag(CGPoint(x: 200, y: 160), CGPoint(x: 224, y: 182))
check(canvas.imageOffset == CGPoint(x: previousOffset.x + 24, y: previousOffset.y + 22) && canvas.cropSelection == disabledCrop,
      "With editing disabled, the original unmodified drag gesture still pans")
canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 300, y: 250), clicks: 2))
check(canvas.fitsWindow, "With editing disabled, the original double-click fit gesture still works")
var navigation = 0, animations = 0, slideshows = 0
canvas.onNavigate = { navigation += $0 }
canvas.onToggleAnimation = { animations += 1 }
canvas.onToggleSlideshow = { slideshows += 1 }
for (code, characters) in [(UInt16(124), ""), (UInt16(49), " "), (UInt16(1), "s")] {
  canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
}
check(navigation == 1 && animations == 1 && slideshows == 1, "Nonediting navigation, animation and slideshow keyboard actions remain intact")
canvas.display(nil, resetZoom: true)
check(canvas.cropSelection == nil && canvas.cropRectInView == nil, "Closing an image clears selection and overlay geometry")
check(canvas.accessibilityHelp() == nil, "Leaving crop mode clears edit-only accessibility instructions")
print("SUCCESS: \(checks) image crop checks passed")
