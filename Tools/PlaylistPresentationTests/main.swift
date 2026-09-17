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

let canvas = PresentationCanvas(frame: NSRect(x: 0, y: 0, width: 270, height: 270))
let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 270, height: 270),
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

let filterControls = PlaylistTagFilterControls(frame: NSRect(x: 0, y: 58, width: 270, height: 38))
canvas.addSubview(filterControls)
let filterLabel = descendants(filterControls).first {
  $0.identifier?.rawValue == "playlist.tag-filter.label"
} as! NSTextField
let filterCount = descendants(filterControls).first {
  $0.identifier?.rawValue == "playlist.tag-filter.count"
} as! NSTextField
let expectedFilters: [PlaylistTagFilter] = [
  .all, .color(6), .color(7), .color(5), .color(2), .color(4), .color(3), .color(1), .color(0), .untagged,
]
check(PlaylistTagFilter.allCases == expectedFilters,
      "The menu offers all files, Finder colors in familiar order, uncolored tags, and no tags")
check(filterControls.intrinsicContentSize.height == 38, "The filter row advertises a compact 38-point native height")
check(filterControls.filterPopup.itemTitles == expectedFilters.map(\.title),
      "The real filter popup uses localized color names, not arbitrary Finder tag names")
check(filterControls.filterPopup.selectedItem?.title == PlaylistTagFilter.all.title && filterCount.stringValue == "0/0",
      "New filter controls start with all files and an empty count")
check(filterControls.filterPopup.accessibilityLabel() == playlistBrowserString("filter.label"),
      "The color selector exposes its localized accessible label")
var filterChanges = [PlaylistTagFilter]()
filterControls.onFilterChange = { filter in
  filterChanges.append(filter)
  filterControls.update(filter: filter, matchingCount: 3, totalCount: 24, busy: false)
}
for (index, filter) in expectedFilters.enumerated() {
  filterControls.filterPopup.selectItem(at: index)
  action(filterControls.filterPopup)
  check(filterChanges.last == filter, "Selecting filter item \(index) delivers the matching stored-color filter")
  check(filterControls.filterPopup.toolTip?.contains(filter.title) == true,
        "The selected filter title is available without opening the menu")
  check(filterControls.filterPopup.item(at: index)?.image != nil || filter == .all || filter == .untagged,
        "Every actual Finder color menu item has a native image")
}
let beforeFilterUpdate = filterChanges.count
filterControls.update(filter: .color(6), matchingCount: 12_345, totalCount: 98_765, busy: true)
check(filterChanges.count == beforeFilterUpdate, "Refreshing filter counts does not dispatch a new filter request")
check(filterControls.filterPopup.isEnabled, "Reading metadata never disables the color selector")
check(filterCount.toolTip?.contains(playlistBrowserString("filter.busy")) == true &&
      filterControls.filterPopup.accessibilityHelp()?.contains(playlistBrowserString("filter.busy")) == true,
      "Reading metadata is explained in both tooltip and accessibility")
check(filterControls.toolTip?.contains(playlistBrowserString("filter.scope")) == true &&
      filterControls.filterPopup.toolTip?.contains(playlistBrowserString("filter.scope")) == true,
      "The filter explicitly explains that the underlying playback queue stays unchanged")
let fullNumberFormatter = NumberFormatter()
fullNumberFormatter.numberStyle = .decimal
check(filterCount.accessibilityLabel()?.contains(fullNumberFormatter.string(from: 12_345)!) == true &&
      filterCount.accessibilityLabel()?.contains(fullNumberFormatter.string(from: 98_765)!) == true,
      "Abbreviated visual counts retain complete matching and total numbers for accessibility")
check(filterCount.stringValue.contains("k") && filterCount.stringValue.count < 12,
      "Large lists use compact visual counts")
filterControls.filterPopup.selectItem(at: 2)
action(filterControls.filterPopup)
check(filterChanges.count == beforeFilterUpdate + 1 && filterChanges.last == .color(7),
      "A real popup action can change the selected filter while metadata is busy")
check(filterCount.toolTip?.contains(playlistBrowserString("filter.busy")) == false,
      "Completed metadata refresh removes the previous busy description")
filterControls.filterPopup.select(nil)
let beforeMissingSelection = filterChanges.count
action(filterControls.filterPopup)
check(filterChanges.count == beforeMissingSelection, "An absent menu selection cannot deliver an invalid filter")
filterControls.update(filter: .color(99), matchingCount: -4, totalCount: -8, busy: false)
check(filterControls.filterPopup.indexOfSelectedItem == 0 && filterCount.stringValue == "0/0",
      "Unsupported filter state and transient negative counts fall back safely")
filterControls.update(filter: .untagged, matchingCount: 999, totalCount: 2, busy: false)
check(filterCount.stringValue == "2/2", "A transient stale matching count cannot exceed the current total")
filterControls.update(filter: .color(0), matchingCount: 0, totalCount: 42, busy: false)
check(filterCount.stringValue == "0/42" && filterControls.filterPopup.selectedItem?.title == PlaylistTagFilter.color(0).title,
      "A zero-match filter keeps its distinct uncolored-tag selection visible")
let language = Bundle.main.preferredLocalizations.first ?? "en"
let expectedFilterTitles = language == "zh-Hans"
  ? ["全部文件", "红色", "橙色", "黄色", "绿色", "蓝色", "紫色", "灰色", "无色标签", "无标签"]
  : ["All files", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray", "Uncolored tags", "No tags"]
check(filterControls.filterPopup.itemTitles == expectedFilterTitles &&
      playlistBrowserString("filter.empty") != "filter.empty",
      "The full menu and empty-list message are translated in \(language)")

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
  let view = PlaylistTagListView(frame: NSRect(x: 12, y: 120 + index * 38, width: 246, height: 20))
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
  for (index, filter) in expectedFilters.enumerated() {
    guard case .color(let colorIndex) = filter,
          let image = filterControls.filterPopup.item(at: index)?.image else { continue }
    let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
    imageView.image = image
    imageView.appearance = NSAppearance(named: appearance)
    let menuBitmap = snapshot(imageView)
    if colorIndex > 0 {
      let expected = labelColors[colorIndex]
      let found = (0..<menuBitmap.pixelsWide).contains { x in
        menuBitmap.colorAt(x: x, y: menuBitmap.pixelsHigh / 2).map { close($0, expected) } ?? false
      }
      check(found, "The real menu image renders stored Finder color \(colorIndex) in \(appearance.rawValue)")
    } else {
      let middle = menuBitmap.colorAt(x: menuBitmap.pixelsWide / 2, y: menuBitmap.pixelsHigh / 2)
      check((middle?.alphaComponent ?? 1) < 0.1,
            "The uncolored-tag menu image keeps its center hollow in \(appearance.rawValue)")
    }
  }
}

let artifactDirectory = ProcessInfo.processInfo.environment["CHENGYING_CAPTURE_DIR"].map {
  URL(fileURLWithPath: $0, isDirectory: true)
}
if let artifactDirectory { try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true) }
for width in [240, 270, 360, 800] {
  window.setContentSize(NSSize(width: width, height: 270))
  controls.frame.size.width = CGFloat(width)
  filterControls.frame.size.width = CGFloat(width)
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
    for (matching, total) in [(3, 24), (12_345, 98_765), (Int.max, Int.max)] {
      filterControls.update(filter: .color(6), matchingCount: matching, totalCount: total, busy: false)
      filterControls.layoutSubtreeIfNeeded()
      for control in [filterLabel, filterControls.filterPopup, filterCount] as [NSView] {
        let rect = control.convert(control.bounds, to: filterControls)
        check(rect.width > 0 && rect.height > 0 && filterControls.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect),
              "The filter \(type(of: control)) remains inside its 38-point row at \(width) points for \(total) files")
        check(!control.hasAmbiguousLayout, "The filter \(type(of: control)) has unambiguous layout in \(theme) mode")
      }
      let labelFrame = filterLabel.convert(filterLabel.bounds, to: filterControls)
      let popupFrame = filterControls.filterPopup.convert(filterControls.filterPopup.bounds, to: filterControls)
      let countFrame = filterCount.convert(filterCount.bounds, to: filterControls)
      check(labelFrame.maxX <= popupFrame.minX && popupFrame.maxX <= countFrame.minX,
            "The filter label, popup and count never overlap at \(width) points for \(total) files")
    }
    filterControls.update(filter: .color(6), matchingCount: 3, totalCount: 24, busy: false)
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
