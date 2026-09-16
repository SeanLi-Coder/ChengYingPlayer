import Cocoa

setbuf(stdout, nil)
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
  guard value() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}

final class ActionTarget: NSObject {
  var clicks = 0
  @objc func activate(_ sender: NSButton) { clicks += 1 }
}

let target = ActionTarget()
let primary = NSButton(title: "Export", target: target, action: #selector(ActionTarget.activate(_:)))
let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 320, height: 100),
                      styleMask: [.titled], backing: .buffered, defer: false)
primary.frame = NSRect(x: 10, y: 10, width: 280, height: 40)
window.contentView?.addSubview(primary)
primary.tag = 42
primary.keyEquivalent = "g"
primary.keyEquivalentModifierMask = [.command, .shift]
primary.setAccessibilityLabel("Export a new video")
primary.toolTip = "Keep the original file"
primary.isEnabled = false
ChengYingStyle.primaryButton(primary)
check(primary.cell is ChengYingPrimaryButtonCell, "Primary actions use the actual branded native cell")
check(primary.tag == 42 && primary.title == "Export", "Applying the style preserves action identity")
check(primary.target === target && primary.action == #selector(ActionTarget.activate(_:)), "The original target and action survive styling")
check(primary.keyEquivalent == "g" && primary.keyEquivalentModifierMask == [.command, .shift], "Keyboard equivalents survive styling")
check(primary.accessibilityLabel() == "Export a new video" && primary.toolTip == "Keep the original file", "Accessibility labels and tooltips survive styling")
check(!primary.isEnabled, "Unavailable primary actions remain disabled")
primary.performClick(nil)
check(target.clicks == 0, "A disabled styled action cannot execute")
primary.isEnabled = true
primary.performClick(nil)
check(target.clicks == 1, "An enabled styled action executes its real target")
let originalCell = primary.cell
ChengYingStyle.primaryButton(primary)
check(primary.cell === originalCell, "Styling is idempotent")
primary.performClick(nil)
check(target.clicks == 2, "Repeated styling does not lose the action")
let nativeTarget = ActionTarget()
let nativeButton = NSButton(title: "Native", target: nativeTarget, action: #selector(ActionTarget.activate(_:)))
nativeButton.frame = NSRect(x: 10, y: 60, width: 280, height: 30)
window.contentView?.addSubview(nativeButton)
let nativePressResult = nativeButton.accessibilityPerformPress()
let styledPressResult = primary.accessibilityPerformPress()
check(styledPressResult == nativePressResult && nativeTarget.clicks == 1 && target.clicks == 3,
      "Accessibility press matches the native control and executes the real action")

let tab = NSButton(title: "Tools", target: target, action: #selector(ActionTarget.activate(_:)))
tab.tag = 3
tab.isEnabled = false
tab.keyEquivalent = "s"
tab.keyEquivalentModifierMask = [.command]
ChengYingStyle.tabButton(tab, selected: true)
check(tab.tag == 3 && tab.target === target, "Sidebar navigation keeps its tag and target")
check(!tab.isEnabled && tab.keyEquivalent == "s" && tab.keyEquivalentModifierMask == [.command],
      "Sidebar styling preserves disabled state and keyboard equivalents")
check((tab.cell as? ChengYingTabButtonCell)?.isSelectedTab == true, "The active sidebar tab is explicitly selected")
tab.isEnabled = true
tab.performClick(nil)
check(target.clicks == 4, "Styled sidebar navigation still executes")
ChengYingStyle.tabButton(tab, selected: false)
check((tab.cell as? ChengYingTabButtonCell)?.isSelectedTab == false, "Inactive sidebar tabs remove selection styling")

func resolved(_ color: NSColor, appearance: NSAppearance.Name) -> NSColor {
  var result: NSColor!
  NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
    result = color.usingColorSpace(.sRGB)
  }
  return result
}
let darkSurface = resolved(ChengYingStyle.surface, appearance: .darkAqua)
let lightSurface = resolved(ChengYingStyle.surface, appearance: .aqua)
check(darkSurface.redComponent < 0.2 && lightSurface.redComponent > 0.9,
      "Surface colors resolve independently in dark and light windows")
check(resolved(ChengYingStyle.accent, appearance: .darkAqua).blueComponent > 0.8,
      "Dark-mode accents remain bright enough to distinguish controls")

let content = NSTextField(labelWithString: "A local video workflow")
let card = ChengYingStyle.card(content)
window.setContentSize(NSSize(width: 320, height: 200))
window.contentView!.addSubview(card)
NSLayoutConstraint.activate([
  card.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16),
  card.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -8),
  card.widthAnchor.constraint(equalToConstant: 288),
  card.heightAnchor.constraint(equalToConstant: 52),
])
window.contentView!.layoutSubtreeIfNeeded()
check(card is ChengYingCardView, "Sections use the production card renderer")
let alignedContent = content.alignmentRect(forFrame: content.frame)
check(alignedContent.minX >= 11 && alignedContent.maxX <= 277,
      "Card content keeps readable horizontal padding: \(alignedContent)")
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
  card.appearance = NSAppearance(named: appearance)
  let bitmap = card.bitmapImageRepForCachingDisplay(in: card.bounds)!
  card.cacheDisplay(in: card.bounds, to: bitmap)
  check(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "The real card draws in \(appearance.rawValue)")
}
print("Visual style checks passed: \(checks)")
