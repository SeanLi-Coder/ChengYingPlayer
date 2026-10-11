import Cocoa

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  checks += 1
  if !condition() { fputs("File action check failed: \(message)\n", stderr); exit(1) }
}
func waitFor(_ message: String, _ condition: () -> Bool) {
  let deadline = Date().addingTimeInterval(8)
  while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
  expect(condition(), message)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("synthetic-files", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

func folder(_ path: String) throws -> URL {
  let result = root.appendingPathComponent(path, isDirectory: true)
  try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
  return result
}
func file(_ path: String, _ text: String = "synthetic-media") throws -> URL {
  let result = root.appendingPathComponent(path)
  try FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(text.utf8).write(to: result)
  return result
}
func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
func contents(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
func clipboardURLs(_ clipboard: NSPasteboard) -> [URL] {
  (clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
}
func replaceClipboard(_ clipboard: NSPasteboard, with urls: [URL]) {
  clipboard.clearContents()
  expect(clipboard.writeObjects(urls.map { $0 as NSURL }), "External file clipboard can be written")
}

final class State: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  var urls: [URL] = []
  var destination: URL?
  var allowed = true
  var protected: [URL] = []
  var reports: [MediaFileTransfer.Report] = []
  var messages: [(String, Bool)] = []
  var selections = 0
  func numberOfRows(in tableView: NSTableView) -> Int { urls.count }
  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
    urls.indices.contains(row) ? urls[row].lastPathComponent : nil
  }
  func tableViewSelectionDidChange(_ notification: Notification) { selections += 1 }
  func urls(for rows: IndexSet) -> [URL] { rows.compactMap { urls.indices.contains($0) ? urls[$0] : nil } }
}

final class Fixture {
  let state = State()
  let table = FileListTableView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
  let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 420))
  let text = NSTextField(frame: NSRect(x: 0, y: 380, width: 300, height: 24))
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
  let clipboard = NSPasteboard.withUniqueName()
  let actions: MediaFileActions

  init(_ urls: [URL], destination: URL,
       executor: @escaping ([MediaFileTransfer.Source], MediaFileTransfer.Source,
                             MediaFileTransfer.Operation) -> MediaFileTransfer.Report = MediaFileTransfer.execute) {
    let state = state, table = table
    state.urls = urls
    state.destination = destination
    actions = MediaFileActions(tableView: table,
      selectedURLs: { state.urls(for: table.selectedRowIndexes) },
      URLsForRows: { state.urls(for: $0) }, destinationURL: { state.destination },
      canOperate: { state.allowed }, protectedURLs: { state.protected },
      didTransfer: { state.reports.append($0) },
      presentation: { state.messages.append(($0, $1)) }, pasteboard: clipboard, executor: executor)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fixture"))
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 30
    table.dataSource = state
    table.delegate = state
    table.allowsMultipleSelection = true
    container.addSubview(table)
    container.addSubview(text)
    window.isReleasedWhenClosed = false
    window.contentView = container
    window.orderFront(nil)
    table.reloadData()
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    expect(window.makeFirstResponder(table), "File table accepts focus")
  }

  deinit {
    window.orderOut(nil)
    window.close()
    clipboard.releaseGlobally()
  }

  func key(_ character: String, _ modifiers: NSEvent.ModifierFlags = .command,
           throughWindow: Bool = false) -> Bool {
    let code: UInt16 = character == "c" ? 8 : character == "x" ? 7 : 9
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
      characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
    return throughWindow ? window.performKeyEquivalent(with: event) : table.performKeyEquivalent(with: event)
  }

  func menu(row: Int?) -> NSMenu {
    let point: NSPoint
    if let row {
      let rect = table.rect(ofRow: row)
      point = NSPoint(x: rect.midX, y: rect.midY)
    } else { point = NSPoint(x: 20, y: 300) }
    let event = NSEvent.mouseEvent(with: .rightMouseDown, location: table.convert(point, to: nil),
      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    return table.menu(for: event)!
  }

  func invoke(_ item: NSMenuItem) {
    expect(NSApp.sendAction(item.action!, to: item.target, from: item), "Context menu action is delivered")
  }
}

do {
  let original = try file("copy/source/photo.jpg", "copy-bytes")
  let target = try folder("copy/target")
  let fixture = Fixture([original], destination: target)
  expect(fixture.key("c"), "Command-C is handled by the focused file list")
  expect(clipboardURLs(fixture.clipboard) == [original], "Copy exports a Finder-compatible file URL")
  expect(fixture.key("v"), "Command-V starts a file copy")
  expect(MediaFileActions.pendingOperationCount == 1, "Copy is pending before returning to the run loop")
  expect(MediaFileActions.pendingMoveCount == 0, "Copy does not reserve the playback move barrier")
  expect(!UpdateWorkAdmission.shared.isOpeningMediaBlocked, "Copy leaves new playback admission available")
  expect(UpdateWorkAdmission.shared.activeReasons.contains("busy.files"), "Copy owns an update activity lease")
  waitFor("Copy completes") { fixture.state.reports.count == 1 }
  expect(contents(target.appendingPathComponent("photo.jpg")) == "copy-bytes", "Copy preserves actual file bytes")
  expect(exists(original), "Copy keeps the source")
  expect(clipboardURLs(fixture.clipboard) == [original], "Copy keeps the file clipboard")
  expect(MediaFileActions.pendingOperationCount == 0 && UpdateWorkAdmission.shared.activeReasons.isEmpty,
         "Copy completion releases the activity lease")

  let cutSource = try file("cut/source/movie.mp4", "cut-bytes")
  fixture.state.urls = [cutSource]
  fixture.state.destination = try folder("cut/target")
  fixture.table.reloadData()
  fixture.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
  expect(fixture.key("x"), "Command-X stages a cut")
  expect(exists(cutSource), "Cut does not remove the source before paste")
  expect(fixture.key("v"), "Command-V consumes the cut intent")
  waitFor("Cut-paste completes") { fixture.state.reports.count == 2 }
  expect(!exists(cutSource) && contents(fixture.state.destination!.appendingPathComponent("movie.mp4")) == "cut-bytes",
         "Cut-paste moves the file")
  expect(clipboardURLs(fixture.clipboard).isEmpty, "Successful cut-paste cannot replay the moved source")

  let moveSource = try file("move/source/movie.mp4", "finder-move")
  fixture.state.urls = [moveSource]
  fixture.state.destination = try folder("move/target")
  fixture.table.reloadData()
  fixture.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
  expect(fixture.key("c"), "Copy precedes the Finder move shortcut")
  expect(fixture.key("v", [.command, .option], throughWindow: true),
         "Option-Command-V reaches the focused table through the native window")
  waitFor("Finder-style move completes") { fixture.state.reports.count == 3 }
  expect(!exists(moveSource) && exists(fixture.state.destination!.appendingPathComponent("movie.mp4")),
         "Option-Command-V moves an ordinary copied file")
}

do {
  let first = try file("menu/source/a.jpg"), second = try file("menu/source/b.jpg")
  let target = try folder("menu/target")
  let fixture = Fixture([first, second], destination: target)
  let selected = fixture.table.selectedRowIndexes, events = fixture.state.selections
  let menu = fixture.menu(row: 1)
  expect(menu.items.count == 4, "Context menu has Copy, Cut, Paste, and Move Here")
  expect(fixture.table.selectedRowIndexes == selected && fixture.state.selections == events,
         "Right-clicking another row does not activate another image")
  fixture.state.urls = [second, first]
  fixture.table.reloadData()
  fixture.invoke(menu.items[0])
  expect(clipboardURLs(fixture.clipboard) == [second], "Open context menu retains the clicked file identity after reorder")

  let blankMenu = fixture.menu(row: nil)
  expect(!blankMenu.items[0].isEnabled && !blankMenu.items[1].isEnabled && blankMenu.items[2].isEnabled,
         "Blank area offers paste without reusing an old selected row")
  fixture.invoke(blankMenu.items[2])
  waitFor("Blank-area paste completes") { fixture.state.reports.count == 1 }
  expect(exists(target.appendingPathComponent("b.jpg")) && !exists(target.appendingPathComponent("a.jpg")),
         "Blank-area paste uses the displayed destination folder")

  fixture.table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
  let multiMenu = fixture.menu(row: 0)
  fixture.invoke(multiMenu.items[0])
  expect(Set(clipboardURLs(fixture.clipboard)) == Set([first, second]), "Right-click inside the selection retains all selected files")

  let staleFileMenu = fixture.menu(row: 0)
  let savedCount = fixture.clipboard.changeCount
  try FileManager.default.moveItem(at: second, to: second.deletingLastPathComponent().appendingPathComponent("saved.jpg"))
  try Data("replacement".utf8).write(to: second)
  fixture.invoke(staleFileMenu.items[0])
  expect(fixture.clipboard.changeCount == savedCount && fixture.state.messages.last?.1 == true,
         "A replaced context target cannot silently replace clipboard contents")

  replaceClipboard(fixture.clipboard, with: [first])
  let staleClipboard = fixture.menu(row: nil)
  replaceClipboard(fixture.clipboard, with: [second])
  fixture.invoke(staleClipboard.items[2])
  expect(fixture.state.reports.count == 1 && !exists(target.appendingPathComponent("a.jpg")),
         "A stale paste menu cannot use a newer clipboard or its old payload")
}

do {
  let original = try file("collision/source/a.jpg", "original")
  let target = try folder("collision/target")
  let existing = try file("collision/target/a.jpg", "keep-existing")
  let fixture = Fixture([original], destination: target)
  expect(fixture.key("x"), "Collision test stages cut")
  let count = fixture.clipboard.changeCount
  expect(fixture.key("v"), "Collision paste is handled")
  waitFor("Collision returns an error report") { fixture.state.reports.count == 1 }
  expect(fixture.state.reports[0].successes.isEmpty && fixture.state.reports[0].failures.count == 1,
         "Name collision is reported as failure")
  expect(contents(original) == "original" && contents(existing) == "keep-existing", "Collision preserves both files")
  expect(fixture.clipboard.changeCount == count && clipboardURLs(fixture.clipboard) == [original],
         "Failed cut preserves its clipboard for retry")

  let other = try file("collision/source/b.jpg", "move-other")
  fixture.state.urls = [original, other]
  fixture.table.reloadData()
  fixture.table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
  expect(fixture.key("x") && fixture.key("v"), "Partial cut starts")
  waitFor("Partial cut completes") { fixture.state.reports.count == 2 }
  expect(fixture.state.reports[1].successes.count == 1 && fixture.state.reports[1].failures.count == 1,
         "Partial cut reports success and failure independently")
  expect(exists(original) && !exists(other) && exists(target.appendingPathComponent("b.jpg")),
         "Partial cut only moves the successful source")
  expect(clipboardURLs(fixture.clipboard) == [original], "Partial cut retains only the failed source")
  try FileManager.default.removeItem(at: existing)
  expect(fixture.key("v"), "Failed item can be retried with its existing cut clipboard")
  waitFor("Retried cut completes") { fixture.state.reports.count == 3 }
  expect(!exists(original) && contents(existing) == "original", "Retried partial cut preserves move intent")
}

do {
  let original = try file("new-clipboard/source/a.jpg")
  let target = try folder("new-clipboard/target")
  let fixture = Fixture([original], destination: target)
  expect(fixture.key("x"), "Original clipboard contains cut intent")
  replaceClipboard(fixture.clipboard, with: [original])
  expect(fixture.key("v"), "External clipboard can be pasted")
  waitFor("External copy completes") { fixture.state.reports.count == 1 }
  expect(exists(original) && exists(target.appendingPathComponent("a.jpg")),
         "A rewritten clipboard cannot inherit an old cut intent")

  let before = fixture.clipboard.changeCount
  fixture.text.stringValue = "Text editing must retain its own shortcuts"
  expect(fixture.window.makeFirstResponder(fixture.text), "Text field accepts focus")
  expect(!fixture.key("c") && !fixture.key("x") && !fixture.key("v") && !fixture.key("v", [.command, .option]),
         "File table does not intercept text field shortcuts")
  expect(fixture.clipboard.changeCount == before, "Text-focused shortcut probes do not read or replace file clipboard")
  fixture.table.copy(nil)
  expect(fixture.clipboard.changeCount == before, "Direct table responder action respects focus")
  expect(fixture.window.makeFirstResponder(fixture.table), "Table focus can be restored")
  fixture.table.isHidden = true
  expect(!fixture.key("c"), "Hidden table does not intercept shortcuts")
  fixture.actions.copy(nil)
  expect(fixture.clipboard.changeCount == before, "Hidden table cannot mutate clipboard through its controller")
  expect(!fixture.actions.menu(for: [0]).items[0].isEnabled, "Hidden table menu actions are disabled")
  fixture.table.isHidden = false
  fixture.container.isHidden = true
  expect(!fixture.key("x"), "Hidden ancestor also disables shortcuts")
  fixture.container.isHidden = false
  fixture.window.orderOut(nil)
  fixture.actions.copy(nil)
  expect(fixture.clipboard.changeCount == before, "Closed presentation cannot perform file operations")
}

do {
  let child = try file("protected/source/nested/photo.jpg")
  let directory = child.deletingLastPathComponent()
  let target = try folder("protected/target")
  let fixture = Fixture([child], destination: target)
  fixture.state.protected = [child]
  expect(fixture.key("x") && fixture.key("v"), "Protected source shortcut is consumed safely")
  expect(fixture.state.reports.isEmpty && exists(child) && MediaFileActions.pendingOperationCount == 0,
         "Moving an active exact source is refused before dispatch")
  fixture.state.urls = [directory]
  fixture.table.reloadData()
  fixture.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
  expect(fixture.key("x") && fixture.key("v"), "Ancestor move shortcut is consumed safely")
  expect(fixture.state.reports.isEmpty && exists(child), "Moving an active source ancestor is refused")
  fixture.state.protected = []
  MediaFileActions.additionalProtectedURLs = { [child] }
  expect(fixture.key("v"), "Global active media protection is checked")
  expect(fixture.state.reports.isEmpty && exists(child), "Global protection also checks ancestor moves")
  MediaFileActions.additionalProtectedURLs = { [] }
  MediaFileActions.additionalAdmission = { false }
  let before = fixture.clipboard.changeCount
  fixture.actions.copy(nil)
  expect(fixture.clipboard.changeCount == before && fixture.state.reports.isEmpty,
         "Global protected-work admission blocks file actions")
  MediaFileActions.additionalAdmission = { true }
}

final class Flag {
  private let lock = NSLock()
  private var value = false
  func set() { lock.lock(); value = true; lock.unlock() }
  var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
do {
  let original = try file("background/source/a.jpg")
  let replacement = try file("background/source/b.jpg")
  let target = try folder("background/target")
  let entered = Flag(), release = DispatchSemaphore(value: 0)
  let fixture = Fixture([original], destination: target) { sources, destination, operation in
    entered.set()
    guard release.wait(timeout: .now() + 10) == .success else {
      return MediaFileTransfer.Report(successes: [], failures: sources.map {
        MediaFileTransfer.Failure(source: $0.url, error: CocoaError(.userCancelled))
      })
    }
    return MediaFileTransfer.execute(sources: sources, destination: destination, operation: operation)
  }
  expect(fixture.key("x") && fixture.key("v"), "Controlled background move starts")
  waitFor("Worker reaches the deterministic barrier") { entered.isSet }
  expect(fixture.actions.pendingOperationCount == 1 && MediaFileActions.pendingOperationCount == 1,
         "Background work retains local and process activity counts")
  expect(MediaFileActions.pendingMoveCount == 1, "Background move reserves the playback move barrier")
  expect(UpdateWorkAdmission.shared.activeReasons == ["busy.fileMove"], "Move activity lease survives asynchronous dispatch")
  expect(UpdateWorkAdmission.shared.isOpeningMediaBlocked, "Move blocks new playback admission")
  let installation = UUID()
  expect(!UpdateWorkAdmission.shared.acquire(installation), "Automatic update cannot install during file work")
  let before = fixture.clipboard.changeCount
  fixture.actions.copy(nil)
  expect(fixture.clipboard.changeCount == before && fixture.state.reports.isEmpty,
         "A second operation is rejected while a transfer is pending")
  replaceClipboard(fixture.clipboard, with: [replacement])
  let changedCount = fixture.clipboard.changeCount
  release.signal()
  waitFor("Background move completes after releasing the barrier") { fixture.state.reports.count == 1 }
  expect(!exists(original) && exists(target.appendingPathComponent("a.jpg")), "Worker executes the captured move")
  expect(clipboardURLs(fixture.clipboard) == [replacement] && fixture.clipboard.changeCount == changedCount,
         "Late completion cannot clear or rewrite a newer clipboard")
  expect(MediaFileActions.pendingOperationCount == 0 && UpdateWorkAdmission.shared.activeReasons.isEmpty,
         "Completion balances every activity lease")
  expect(MediaFileActions.pendingMoveCount == 0, "Move completion releases the playback move barrier")
  expect(!UpdateWorkAdmission.shared.isOpeningMediaBlocked, "Move completion restores playback admission")
  expect(UpdateWorkAdmission.shared.acquire(installation), "Installation barrier becomes available after completion")
  expect(UpdateWorkAdmission.shared.isOpeningMediaBlocked, "Installation also blocks new playback admission")
  let retained = fixture.clipboard.changeCount
  fixture.actions.copy(nil)
  fixture.actions.paste(nil)
  expect(fixture.clipboard.changeCount == retained && MediaFileActions.pendingOperationCount == 0,
         "Installation barrier prevents new file work")
  UpdateWorkAdmission.shared.release(installation)
}

try runPlaylistRelocationTests()
expect(MediaFileActions.pendingOperationCount == 0 && UpdateWorkAdmission.shared.activeReasons.isEmpty,
       "Suite leaves no pending transfers or update leases")
print("PASS: \(checks) native file action checks with isolated clipboards and real filesystem transfers")
