import Cocoa

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
setbuf(stdout, nil)
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}

final class PresentationCanvas: NSView {
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    ChengYingStyle.surface.setFill()
    dirtyRect.fill()
  }
}

func descendants(_ view: NSView) -> [NSView] {
  [view] + view.subviews.flatMap(descendants)
}

func action(_ control: NSControl) {
  guard let selector = control.action else { fatalError("The real control is missing its action") }
  check(control.sendAction(selector, to: control.target), "The production control delivers its action")
}

let canvas = PresentationCanvas(frame: NSRect(x: 0, y: 0, width: 270, height: 230))
let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 270, height: 230),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = canvas
let controls = PlaylistSortControls(frame: NSRect(x: 0, y: 16, width: 270, height: 40))
canvas.addSubview(controls)
var changes = [(PlaylistFileSortKey, Bool)]()
var refreshes = 0
controls.onSortChange = { key, ascending in
  changes.append((key, ascending))
  // The owner reflects the committed order through the production update API.
  controls.update(key: key, ascending: ascending, manual: false, busy: false)
}
controls.onRefresh = { refreshes += 1 }
check(controls.sortKey == .name && controls.ascending, "New controls default to natural name ascending")
check(controls.keyPopup.numberOfItems == 5, "Four metadata keys and a manual-order indicator are available")
check(controls.keyPopup.itemTitles == PlaylistFileSortKey.allCases.map(\.title) + [playlistBrowserString("sort.manual")],
      "The actual popup uses localized names for all four sort keys")
check(controls.keyPopup.accessibilityLabel() == playlistBrowserString("sort.label"), "The sort selector has an accessible localized label")

for (index, key) in PlaylistFileSortKey.allCases.enumerated() {
  controls.keyPopup.selectItem(at: index)
  action(controls.keyPopup)
  check(changes.last?.0 == key && changes.last?.1 == true, "Selecting \(key.rawValue) delivers the matching key without changing direction")
  check(controls.keyPopup.toolTip?.contains(key.title) == true, "The selected \(key.rawValue) key is reflected in its tooltip")
}
let beforeDirection = changes.count
controls.directionButton.performClick(nil)
check(changes.count == beforeDirection + 1 && changes.last?.0 == .created && changes.last?.1 == false,
      "The real direction button toggles descending without replacing the selected key")
check(controls.directionButton.accessibilityLabel() == playlistBrowserString("sort.descending"),
      "Descending direction is exposed to accessibility")
controls.directionButton.performClick(nil)
check(controls.ascending && changes.last?.1 == true, "A second direction click restores ascending")

controls.update(key: .size, ascending: false, manual: true, busy: false)
check(controls.keyPopup.selectedItem?.title == playlistBrowserString("sort.manual"), "Manual playback order is shown explicitly")
let beforeManualSelection = changes.count
action(controls.keyPopup)
check(changes.count == beforeManualSelection, "The manual indicator cannot be misread as a metadata sort key")
controls.keyPopup.selectItem(at: 0)
action(controls.keyPopup)
check(changes.last?.0 == .name && changes.last?.1 == false, "Choosing a key exits manual order while preserving direction")

controls.refreshButton.performClick(nil)
check(refreshes == 1, "The real refresh button invokes the refresh callback")
controls.update(key: .modified, ascending: true, manual: false, busy: true)
check(!controls.refreshButton.isEnabled && controls.refreshButton.toolTip == playlistBrowserString("refresh.busy"),
      "Busy metadata refresh is disabled and explained")
controls.refreshButton.performClick(nil)
check(refreshes == 1, "A busy refresh button cannot dispatch duplicate work")
controls.update(key: .name, ascending: true, manual: false, busy: false)
controls.refreshButton.performClick(nil)
check(refreshes == 2 && controls.refreshButton.isEnabled, "The refresh action becomes usable after completion")

let multicolor = [
  PlaylistFileTag(name: "Project review", colorIndex: 6),
  PlaylistFileTag(name: "已完成", colorIndex: 2),
  PlaylistFileTag(name: "Client delivery", colorIndex: 4),
]
let uncolored = [PlaylistFileTag(name: "Personal archive")]
let overflow = [
  PlaylistFileTag(name: "A very long custom Finder tag that must not overwrite adjacent controls", colorIndex: 3),
  PlaylistFileTag(name: "Second tag", colorIndex: 5),
  PlaylistFileTag(name: "Third tag", colorIndex: 7),
]
let tagViews = [multicolor, uncolored, overflow].enumerated().map { index, tags in
  let view = PlaylistTagListView(frame: NSRect(x: 12, y: 88 + index * 38, width: 246, height: 20))
  view.setTags(tags)
  canvas.addSubview(view)
  return view
}
for (index, expected) in [multicolor, uncolored, overflow].enumerated() {
  let view = tagViews[index]
  check(view.tags == expected, "The production tag view preserves names and color indices for row \(index)")
  let description = expected.map(\.name).joined(separator: ", ")
  check(view.toolTip == description && view.accessibilityLabel() == description,
        "Full tag names remain available in tooltip and accessibility even when drawing is truncated")
  check(view.isAccessibilityElement(), "A populated tag view is exposed to accessibility")
}
let emptyTags = PlaylistTagListView(frame: NSRect(x: 0, y: 0, width: 240, height: 20))
emptyTags.setTags(multicolor)
emptyTags.setTags([])
check(emptyTags.tags.isEmpty && emptyTags.toolTip == nil && emptyTags.accessibilityLabel() == "",
      "Clearing tags removes previous names and tooltip content")
check(!emptyTags.isAccessibilityElement(), "An empty tag view does not leave a ghost accessibility element")

func snapshot(_ view: NSView) -> NSBitmapImageRep {
  guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Missing native bitmap") }
  view.effectiveAppearance.performAsCurrentDrawingAppearance {
    view.cacheDisplay(in: view.bounds, to: bitmap)
  }
  return bitmap
}

func close(_ left: NSColor, _ right: NSColor) -> Bool {
  guard let a = left.usingColorSpace(.sRGB), let b = right.usingColorSpace(.sRGB) else { return false }
  return abs(a.redComponent - b.redComponent) < 0.07 && abs(a.greenComponent - b.greenComponent) < 0.07 &&
    abs(a.blueComponent - b.blueComponent) < 0.07 && a.alphaComponent > 0.9
}

// Check the actual drawing, not a replacement tag renderer or hard-coded color mapping.
let colorProbe = PlaylistTagListView(frame: NSRect(x: 0, y: 0, width: 800, height: 20))
colorProbe.setTags(multicolor)
let labelColors = NSWorkspace.shared.fileLabelColors
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
  colorProbe.appearance = NSAppearance(named: appearance)
  let bitmap = snapshot(colorProbe)
  for tag in multicolor {
    let expected = labelColors[tag.colorIndex]
    let middleY = bitmap.pixelsHigh / 2
    let found = (0..<bitmap.pixelsWide).contains { x in
      bitmap.colorAt(x: x, y: middleY).map { close($0, expected) } ?? false
    }
    check(found, "Actual rendering includes stored Finder color \(tag.colorIndex) in \(appearance.rawValue)")
  }
}

let artifactDirectory = ProcessInfo.processInfo.environment["CHENGYING_CAPTURE_DIR"].map {
  URL(fileURLWithPath: $0, isDirectory: true)
}
if let artifactDirectory { try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true) }
let language = Bundle.main.preferredLocalizations.first ?? "en"
for width in [240, 270, 360, 800] {
  window.setContentSize(NSSize(width: width, height: 230))
  controls.frame.size.width = CGFloat(width)
  tagViews.forEach { $0.frame.size.width = CGFloat(width - 24) }
  for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    window.appearance = NSAppearance(named: appearance)
    canvas.layoutSubtreeIfNeeded()
    for control in [controls.keyPopup, controls.directionButton, controls.refreshButton] as [NSView] {
      let rect = control.convert(control.bounds, to: canvas)
      check(rect.width > 0 && rect.height > 0 && rect.minX >= -0.5 && rect.maxX <= CGFloat(width) + 0.5,
            "\(type(of: control)) fits a \(width)-point \(theme) sidebar")
      check(!control.hasAmbiguousLayout, "\(type(of: control)) has unambiguous native layout at \(width) points")
    }
    let popupFrame = controls.keyPopup.convert(controls.keyPopup.bounds, to: canvas)
    let directionFrame = controls.directionButton.convert(controls.directionButton.bounds, to: canvas)
    let refreshFrame = controls.refreshButton.convert(controls.refreshButton.bounds, to: canvas)
    check(popupFrame.maxX <= directionFrame.minX && directionFrame.maxX <= refreshFrame.minX,
          "Sort and refresh controls do not overlap at \(width) points in \(theme) mode")
    check(tagViews.allSatisfy { canvas.bounds.contains($0.frame) }, "All tag rows remain within the \(width)-point sidebar")
    let bitmap = snapshot(canvas)
    check(bitmap.pixelsWide >= width && bitmap.pixelsHigh > 0, "The complete native playlist presentation renders in \(theme) mode at \(width) points")
    if let artifactDirectory, let image = bitmap.representation(using: .png, properties: [:]) {
      let output = artifactDirectory.appendingPathComponent("playlist-\(language)-\(theme)-\(width).png")
      try image.write(to: output)
      print("SNAPSHOT: \(output.path)")
    }
  }
}

print("Playlist presentation checks passed: \(checks)")
