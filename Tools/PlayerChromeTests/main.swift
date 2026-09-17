import Cocoa

private var checks = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}

private func approximately(_ left: CGFloat, _ right: CGFloat) -> Bool { abs(left - right) < 0.6 }

private final class ActionRecorder: NSObject {
  var actions: [Int] = []
  @objc func record(_ sender: NSControl) { actions.append(sender.tag) }
}

private func snapshot(_ view: NSView, name: String, scale: CGFloat, destination: URL) throws -> NSBitmapImageRep {
  let bounds = view.bounds
  let width = Int(ceil(bounds.width * scale))
  let height = Int(ceil(bounds.height * scale))
  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  bitmap.size = bounds.size
  view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: bounds, to: bitmap) }
  let data = bitmap.representation(using: .png, properties: [:])!
  let decoded = NSBitmapImageRep(data: data)!
  print("Screenshot \(name): bounds=\(bounds), backing=\(view.convertToBacking(bounds)), scale=\(scale), pixels=\(width)x\(height)")
  check(decoded.pixelsWide == width && decoded.pixelsHigh == height && data.count > 1024,
        "\(name) captures the actual content dimensions without assuming virtual-screen size")
  var colors = Set<String>()
  for y in stride(from: 0, to: height, by: max(1, height / 30)) {
    for x in stride(from: 0, to: width, by: max(1, width / 30)) {
      if let color = decoded.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9 {
        colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
      }
    }
  }
  check(colors.count > 12, "\(name) includes nonuniform visible content, not a blank screenshot")
  try data.write(to: destination.appendingPathComponent("\(name).png"))
  return decoded
}

private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

private func pixel(_ bitmap: NSBitmapImageRep, point: NSPoint, scale: CGFloat) -> NSColor {
  let x = Int(point.x * scale)
  let y = bitmap.pixelsHigh - 1 - Int(point.y * scale)
  return bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
}

private func sameOpaquePixel(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep, point: NSPoint) -> Bool {
  let left = pixel(first, point: point, scale: 2)
  let right = pixel(second, point: point, scale: 2)
  return abs(left.redComponent - right.redComponent) < 0.008 &&
    abs(left.greenComponent - right.greenComponent) < 0.008 &&
    abs(left.blueComponent - right.blueComponent) < 0.008 && left.alphaComponent > 0.99 && right.alphaComponent > 0.99
}

setbuf(stdout, nil)
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let fixture = try ChromeFixture(xib: URL(fileURLWithPath: CommandLine.arguments[1]))
let timeline = try fixture.fragment("BE1-yC-oJL")
let transport = try fixture.fragment("hDm-KI-3o4") as! NSStackView
let middle = try fixture.fragment("Yv6-0K-6E4")
transport.addView(middle, in: .center)
let volume = try fixture.fragment("N3B-DL-XOA")
let toolbar = try fixture.fragment("KfP-G9-8pD") as! NSStackView
toolbar.spacing = 4
private let recorder = ActionRecorder()
let icons = ["info.circle", "scissors", "captions.bubble", "arrow.down.circle", "gearshape", "list.bullet"]
for (index, symbol) in icons.enumerated() {
  let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)!,
                        target: recorder, action: #selector(ActionRecorder.record(_:)))
  button.tag = 10 + index
  button.isBordered = false
  button.contentTintColor = .white
  button.translatesAutoresizingMaskIntoConstraints = false
  NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 24), button.heightAnchor.constraint(equalToConstant: 24)])
  toolbar.addView(button, in: .trailing)
}
let nativeControls = [timeline, transport, volume].flatMap(descendants).compactMap { $0 as? NSControl }
for (index, control) in nativeControls.enumerated() {
  control.target = recorder
  control.action = #selector(ActionRecorder.record(_:))
  control.tag = 100 + index
}
let play = fixture.view("gxw-pJ-Lcg") as! NSButton
play.keyEquivalent = " "
let oldStack = NSStackView(views: [timeline, transport, volume, toolbar])
var accessibility = PlayerControlsAccessibility(reduceTransparency: false, increaseContrast: false)
let edge = PlayerEdgeControlsView(timeline: timeline, transport: transport, volume: volume, accessibility: { accessibility })
let corner = PlayerCornerControlsView(toolbar: toolbar, accessibility: { accessibility })
check(oldStack.views.isEmpty, "Reparenting removes all original stack ownership")
check(timeline.superview === edge && transport.superview === edge && volume.superview === edge && toolbar.superview === corner,
      "The original control instances are reused, not recreated")
check(timeline is TimeLabelOverflowedView && timeline.alignmentRectInsets.top == 6,
      "The timeline retains the production alignment-inset behavior")
check(nativeControls.allSatisfy { $0.target === recorder && $0.action == #selector(ActionRecorder.record(_:)) },
      "Reparenting preserves every original target and action")
check(play.keyEquivalent == " ", "The existing keyboard equivalent survives reparenting")
let canvas = ChromeSampleVideo(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
canvas.addSubview(edge)
canvas.addSubview(corner)
NSLayoutConstraint.activate([
  edge.leadingAnchor.constraint(equalTo: canvas.leadingAnchor), edge.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
  edge.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
  corner.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 8),
  corner.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -8),
])
let window = NSWindow(contentRect: canvas.bounds, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.contentMinSize = NSSize(width: 285, height: 120)
window.contentView = canvas
window.orderFront(nil)

func validateLayout(_ label: String) {
  canvas.layoutSubtreeIfNeeded()
  let timelineAlignment = timeline.alignmentRect(forFrame: timeline.frame)
  check(approximately(edge.frame.minX, 0) && approximately(edge.frame.minY, 0) &&
        approximately(edge.frame.width, canvas.bounds.width) && approximately(edge.frame.height, 62),
        "\(label): footer is pinned to the complete bottom edge at 62 points")
  check(approximately(timelineAlignment.minX, 8) && approximately(timelineAlignment.minY, 4) &&
        approximately(timelineAlignment.width, edge.bounds.width - 16) && approximately(timelineAlignment.height, 22),
        "\(label): the 22-point timeline spans the bottom with eight-point side insets")
  check(approximately(transport.frame.width, 132) && approximately(volume.frame.width, 104),
        "\(label): XIB-required transport and volume widths remain intact")
  check(transport.frame.maxX + 12 <= volume.frame.minX && transport.frame.minY >= timeline.frame.maxY - 1,
        "\(label): compact controls do not overlap at the actual window width")
  let slider = fixture.view("eBP-6g-bAT")
  check(slider.frame.height >= 16 && slider.frame.width > 120 && timeline.bounds.contains(slider.frame),
        "\(label): the native timeline slider keeps its clickable height without clipping")
  check(approximately(corner.frame.maxX, canvas.bounds.width - 8) &&
        approximately(corner.frame.maxY, canvas.bounds.height - 8) && approximately(corner.frame.height, 36),
        "\(label): the compact icon strip is at the top-right corner")
  check(approximately(corner.frame.width, toolbar.frame.width + 12) && corner.frame.width < 200,
        "\(label): the icon strip hugs its contents instead of becoming a large panel")
  check(!edge.hasAmbiguousLayout && !corner.hasAmbiguousLayout && !timeline.hasAmbiguousLayout &&
        !transport.hasAmbiguousLayout && !volume.hasAmbiguousLayout,
        "\(label): all production layout containers resolve unambiguously")
  let gap = NSPoint(x: (transport.frame.maxX + volume.frame.minX) / 2, y: transport.frame.midY)
  check(edge.hitTest(edge.convert(gap, to: canvas)) == nil, "\(label): empty footer space passes clicks to the video")
  let sliderCenter = slider.convert(NSPoint(x: slider.bounds.midX, y: slider.bounds.midY), to: canvas)
  check(edge.hitTest(sliderCenter) === slider, "\(label): seeking still reaches the existing native slider")
}

for width: CGFloat in [285, 320, 640, 1920] {
  // First exercise exact requested geometry independently of the available CI screen.
  canvas.setFrameSize(NSSize(width: width, height: max(180, width * 9 / 16)))
  validateLayout("Exact \(Int(width))")
  for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    window.appearance = NSAppearance(named: appearance)
    let requested = NSSize(width: width, height: max(180, width * 9 / 16))
    window.setContentSize(requested)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    validateLayout("Window \(Int(width)) \(appearance.rawValue)")
    for scale: CGFloat in [1, 2] {
      _ = try snapshot(canvas, name: "chrome-\(Int(width))-\(appearance == .aqua ? "light" : "dark")-\(Int(scale))x",
                       scale: scale, destination: destination)
    }
  }
}

play.performClick(nil)
check(recorder.actions.last == play.tag, "The reused play button still invokes its original action")
let seek = fixture.view("eBP-6g-bAT") as! NSSlider
seek.doubleValue = 73
_ = NSApp.sendAction(seek.action!, to: seek.target, from: seek)
check(recorder.actions.last == seek.tag && seek.doubleValue == 73, "The reused seek slider preserves value and action delivery")
let finalButton = toolbar.views.last! as! NSButton
finalButton.performClick(nil)
check(recorder.actions.last == finalButton.tag, "The top-right file-list button still invokes its original action")
let allToolbarButtons = toolbar.views
for button in allToolbarButtons.prefix(3) { toolbar.removeView(button) }
canvas.layoutSubtreeIfNeeded()
check(approximately(corner.frame.width, 92) && !corner.hasAmbiguousLayout,
      "Changing toolbar contents resizes the corner strip without replacing its constraints")
for button in toolbar.views { toolbar.removeView(button) }
for button in allToolbarButtons { toolbar.addView(button, in: .trailing) }
canvas.layoutSubtreeIfNeeded()
check(approximately(corner.frame.width, 176), "Restoring the full toolbar restores its content-driven width")
edge.isHidden = true
check(edge.hitTest(edge.convert(NSPoint(x: 20, y: 15), to: canvas)) == nil, "Hidden controls cannot intercept video input")
edge.isHidden = false
edge.alphaValue = 0
check(edge.hitTest(edge.convert(NSPoint(x: 20, y: 15), to: canvas)) == nil, "Fully faded controls cannot intercept video input")
edge.alphaValue = 1
window.setContentSize(NSSize(width: 640, height: 360))
for (index, options) in [PlayerControlsAccessibility(reduceTransparency: true, increaseContrast: false),
                         PlayerControlsAccessibility(reduceTransparency: false, increaseContrast: true),
                         PlayerControlsAccessibility(reduceTransparency: true, increaseContrast: true)].enumerated() {
  accessibility = options
  NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
  RunLoop.current.run(until: Date().addingTimeInterval(0.01))
  check(corner.layer?.borderWidth == (options.increaseContrast ? 1 : 0), "Accessibility mode \(index) updates the contrast outline live")
  validateLayout("Accessibility \(index)")
  let bitmap = try snapshot(canvas, name: "chrome-accessibility-\(index)", scale: 2, destination: destination)
  if options.reduceTransparency {
    canvas.alternateBackground = true
    canvas.needsDisplay = true
    window.displayIfNeeded()
    let alternate = try snapshot(canvas, name: "chrome-accessibility-\(index)-alternate-video", scale: 2, destination: destination)
    let backgroundPoint = NSPoint(x: 20, y: canvas.bounds.midY)
    check(!sameOpaquePixel(bitmap, alternate, point: backgroundPoint),
          "Accessibility mode \(index) uses two visibly different video backgrounds")
    check(sameOpaquePixel(bitmap, alternate, point: corner.convert(NSPoint(x: 8, y: 3), to: canvas)),
          "Accessibility mode \(index) paints the corner above the visual effect with a truly opaque fill")
    check(sameOpaquePixel(bitmap, alternate, point: edge.convert(NSPoint(x: edge.bounds.midX, y: 43), to: canvas)),
          "Accessibility mode \(index) replaces the footer gradient with a truly opaque fill")
    canvas.alternateBackground = false
    canvas.needsDisplay = true
  }
}
window.close()
print("PASS: \(checks) player edge-chrome checks")
