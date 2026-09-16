import Cocoa

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
}

_ = NSApplication.shared
weak var previousController: HistoryWindowController?
autoreleasepool {
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
    styleMask: [.titled], backing: .buffered, defer: false)
  let outline = NSOutlineView(frame: window.contentView!.bounds)
  let search = NSSearchField(frame: .zero)
  window.contentView!.addSubview(outline)
  window.contentView!.addSubview(search)
  outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Filename")))
  var controller: HistoryWindowController? = HistoryWindowController(window: window)
  controller!.outlineView = outline
  controller!.historySearchField = search
  HistoryController.shared.history = [
    PlaybackHistory("/tmp/alpha/Scene.mp4"), PlaybackHistory("/tmp/beta/Other.mp4"),
  ]
  controller!.windowDidLoad()

  func displayedNames() -> [String] {
    guard let controller else { return [] }
    return (0..<controller.outlineView(outline, numberOfChildrenOfItem: nil)).flatMap { index in
      let group = controller.outlineView(outline, child: index, ofItem: nil)
      return (0..<controller.outlineView(outline, numberOfChildrenOfItem: group)).map {
        (controller.outlineView(outline, child: $0, ofItem: group) as! PlaybackHistory).name
      }
    }
  }

  check(displayedNames() == ["Scene.mp4", "Other.mp4"], "An empty search shows all history")
  search.stringValue = "alpha"
  controller!.searchFieldAction(search)
  check(displayedNames() == ["Scene.mp4"], "Full-path history search filters results")
  HistoryController.shared.history.append(PlaybackHistory("/tmp/beta/New.mp4"))
  NotificationCenter.default.post(name: .iinaHistoryUpdated, object: nil)
  check(displayedNames() == ["Scene.mp4"], "Playback updates preserve the active history search")
  controller!.groupBy = .fileLocation
  controller!.reloadData()
  check(displayedNames() == ["Scene.mp4"], "Regrouping preserves the active search")
  controller!.searchOptionFilenameAction(NSMenuItem())
  check(displayedNames().isEmpty, "Changing to filename search immediately reapplies the query")
  controller!.searchOptionFullPathAction(NSMenuItem())
  check(
    displayedNames() == ["Scene.mp4"],
    "Changing back to full-path search immediately refreshes results")
  search.stringValue = "sCenE"
  controller!.searchFieldAction(search)
  check(displayedNames() == ["Scene.mp4"], "Search remains locale-aware and case-insensitive")
  HistoryController.shared.history.removeAll { $0.name == "Scene.mp4" }
  NotificationCenter.default.post(name: .iinaHistoryUpdated, object: nil)
  check(displayedNames().isEmpty, "Removing a filtered group does not restore unrelated entries")
  HistoryController.shared.history.append(PlaybackHistory("/tmp/beta/Scène.mp4"))
  NotificationCenter.default.post(name: .iinaHistoryUpdated, object: nil)
  check(
    displayedNames() == ["Scène.mp4"],
    "New matches appear and searches remain diacritic-insensitive")
  search.stringValue = ""
  controller!.searchFieldAction(search)
  check(displayedNames().count == 3, "Clearing the query restores every entry")
  check(
    controller!.outlineView(outline, numberOfChildrenOfItem: HistoryController.shared.history[0])
      == 0,
    "Leaf history entries have no children")
  check(
    controller!.outlineView(outline, numberOfChildrenOfItem: "removed group") == 0,
    "AppKit can query a stale group after a history update")
  previousController = controller
  outline.delegate = nil
  outline.dataSource = nil
  outline.target = nil
  controller = nil
}
check(previousController == nil, "The history observer does not retain its controller")
NotificationCenter.default.post(name: .iinaHistoryUpdated, object: nil)
check(true, "A history update after controller release cannot call an unowned observer")
print("History search checks passed: \(checks)")
