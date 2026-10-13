import Cocoa
import Darwin

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  checks += 1
  if !condition() { fputs("Folder browser check failed: \(message)\n", stderr); exit(1) }
}
func pump(_ duration: TimeInterval = 0.02) {
  RunLoop.main.run(until: Date().addingTimeInterval(duration))
}
func waitFor(_ message: String, _ condition: () -> Bool) {
  let deadline = Date().addingTimeInterval(5)
  while !condition(), Date() < deadline { pump() }
  expect(condition(), message)
}
func send(_ control: NSControl) {
  guard let action = control.action else { expect(false, "Control has an action"); return }
  NSApp.sendAction(action, to: control.target, from: control)
}
func capture(_ view: NSView, name: String) throws {
  guard let directory = ProcessInfo.processInfo.environment["MEDIA_FOLDER_SCREENSHOT_DIR"] else { return }
  view.layoutSubtreeIfNeeded()
  guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
  view.cacheDisplay(in: view.bounds, to: bitmap)
  guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
  let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
  try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
  let language = Bundle.main.preferredLocalizations.first ?? "en"
  let url = directoryURL.appendingPathComponent(name + "-" + language + ".png")
  try data.write(to: url)
  print("Folder browser screenshot: \(url.path)")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
  .appendingPathComponent("chengying-folder-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
func folder(_ path: String) throws -> URL {
  let url = root.appendingPathComponent(path, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url.standardizedFileURL
}
func file(_ path: String, bytes: Int = 10) throws -> URL {
  let url = root.appendingPathComponent(path)
  try Data(repeating: 0, count: bytes).write(to: url)
  return url.standardizedFileURL
}
func setTags(_ tags: [String], at url: URL) throws {
  let data = try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
  let result = url.path.withCString { path in
    data.withUnsafeBytes { bytes in
      setxattr(path, "com.apple.metadata:_kMDItemUserTags", bytes.baseAddress, data.count, 0, 0)
    }
  }
  expect(result == 0, "Finder tags can be written to fixture")
}
let directory = try folder("Media")
let folder2 = try folder("Media/folder2")
let folder10 = try folder("Media/folder10")
_ = try folder("Media/.hidden")
_ = try folder("Media/Player.app")
let nestedFile = try file("Media/folder2/nested.png")
_ = try file("Media/Player.app/inside.png")
let file2 = try file("Media/2.png", bytes: 200)
let file10 = try file("Media/10.PNG", bytes: 100)
let video = try file("Media/movie.mp4", bytes: 50)
_ = try file("Media/.hidden.png")
_ = try file("Media/readme.txt")
try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("cycle"), withDestinationURL: root)
expect(mkfifo(directory.appendingPathComponent("pipe.png").path, 0o600) == 0, "Special file fixture exists")
try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: file2.path)
try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: file10.path)
try setTags(["Review\n6", "Keep\n2"], at: file2)
try setTags(["FolderTag\n4"], at: folder2)

let filePasteboard = NSPasteboard.withUniqueName()
defer { filePasteboard.releaseGlobally() }
let browser = MediaFolderBrowserView(extensions: ["png", "mp4"], pasteboard: filePasteboard)
browser.appearance = NSAppearance(named: .aqua)
browser.wantsLayer = true
browser.layer?.backgroundColor = NSColor.white.cgColor
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 540),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = browser
window.orderFront(nil)
var callbacks: [(URL, [PlaylistFileMetadata])] = []
var openedFiles: [URL] = []
browser.onDirectoryLoaded = { url, files in
  expect(Thread.isMainThread, "Loaded snapshots arrive on the main thread")
  callbacks.append((url, files))
}
browser.onOpenFile = { openedFiles.append($0) }
expect(!browser.statusLabel.isHidden && !browser.parentButton.isEnabled, "Initial state explains how to select a folder")
browser.showDirectory(directory, selectedURL: file10)
expect(browser.isLoading && callbacks.isEmpty, "Enumeration returns asynchronously")
waitFor("Directory loads") { !browser.isLoading }
expect(browser.loadError == nil, "Valid directory has no error")
expect(browser.visibleEntries.map(\.metadata.name) == ["folder2", "folder10", "2.png", "10.PNG", "movie.mp4"],
       "Directories lead natural filename order; hidden files, packages, symlinks and special files are skipped")
expect(callbacks.last?.1.map(\.url.path) == [file2, file10, video].map(\.path),
       "Snapshot has only accepted direct media files: \(callbacks.last?.1.map(\.url.path) ?? []) vs \([file2, file10, video].map(\.path))")
expect(browser.tableView.selectedRow == 3, "Asynchronous load keeps the requested file selected")
expect(browser.visibleEntries[0].metadata.tags.contains(PlaylistFileTag(name: "FolderTag", colorIndex: 4)),
       "Folder Finder tags are available")
expect(browser.visibleEntries[2].metadata.tags.count == 2, "All file Finder tags are available")
expect(browser.visibleEntries.allSatisfy { $0.url != nestedFile }, "Nested media is not eagerly enumerated")
browser.layoutSubtreeIfNeeded()
expect(browser.tableView.numberOfRows == 5 && browser.parentButton.frame.width >= 26,
       "Folder table and parent control lay out in a narrow sidebar")
try capture(browser, name: "natural-order")

browser.sortControls.keyPopup.selectItem(at: 1)
send(browser.sortControls.keyPopup)
expect(browser.mediaFiles.map(\.url) == [video, file10, file2], "Size ordering uses actual metadata")
expect(browser.visibleEntries.prefix(2).allSatisfy(\.isDirectory), "Size order still keeps all directories first")
expect(browser.tableView.selectedRow == 3, "Sort preserves the selected file identity")
send(browser.sortControls.directionButton)
expect(browser.mediaFiles.map(\.url) == [file2, file10, video], "Descending order reverses file sizes")
browser.sortControls.keyPopup.selectItem(at: 2)
send(browser.sortControls.keyPopup)
expect(browser.mediaFiles.last?.url == file2, "Modification date order uses the stored timestamp")
browser.sortControls.keyPopup.selectItem(at: 3)
send(browser.sortControls.keyPopup)
expect(browser.mediaFiles.allSatisfy { $0.creationDate != nil }, "Creation dates are read for sorting")

let revisionBeforeFilter = browser.mediaFilesRevision
let orderBeforeFilter = browser.mediaFiles
browser.tagFilterControls.filterPopup.selectItem(at: 1)
send(browser.tagFilterControls.filterPopup)
expect(browser.visibleEntries.count == 3 && browser.visibleEntries.last?.url == file2,
       "Red tag filter retains every directory and only matching files")
expect(callbacks.last?.1.map(\.url) == [file2], "Callback exposes visible matching media")
expect(browser.mediaFiles.count == 3, "Unfiltered playback snapshot survives the visual tag filter")
expect(browser.mediaFilesRevision == revisionBeforeFilter && browser.mediaFiles == orderBeforeFilter,
       "Visual filtering preserves the complete sorted snapshot and its revision")
expect(browser.tableView.selectedRow == -1, "Filtered-out selected file is not replaced by another file")
try capture(browser, name: "tag-filter")
browser.tagFilterControls.filterPopup.selectItem(at: 0)
send(browser.tagFilterControls.filterPopup)
expect(browser.visibleEntries[browser.tableView.selectedRow].url == file10, "Clearing filter restores selected file")
expect(browser.mediaFiles == orderBeforeFilter, "Clearing a filter restores the existing sort order exactly")
browser.refresh()
waitFor("An unchanged directory refresh finishes") { !browser.isLoading }
expect(browser.mediaFilesRevision != revisionBeforeFilter && browser.mediaFiles == orderBeforeFilter,
       "Even unchanged refreshes publish a new revision for host identity revalidation")
try setTags(["Review\n4"], at: file2)
NotificationCenter.default.post(name: .playbackFileTagsChanged, object: nil, userInfo: ["url": file2])
waitFor("A tag-change notification refreshes the matching folder") { !browser.isLoading }
expect(browser.mediaFiles.first(where: { $0.url == file2 })?.tags == [PlaylistFileTag(name: "Review", colorIndex: 4)],
       "Refresh rereads changed Finder tags")

browser.canNavigate = { false }
browser.selectFile(file2)
browser.openSelectedEntry()
browser.showDirectory(folder2, force: true)
browser.goToParent()
expect(openedFiles.isEmpty && browser.directoryURL == directory, "Protected work gates file and directory activation")
browser.canNavigate = nil
browser.openSelectedEntry()
expect(openedFiles == [file2], "File activation emits the actual selected media URL")
browser.selectFile(folder2)
browser.openSelectedEntry()
waitFor("Folder activation enters a child") { !browser.isLoading && browser.directoryURL == folder2 }
expect(browser.visibleEntries.map(\.url) == [nestedFile], "Child directory is loaded on explicit navigation")
send(browser.parentButton)
waitFor("Parent navigation returns") { !browser.isLoading && browser.directoryURL == directory }
expect(browser.visibleEntries[browser.tableView.selectedRow].url == folder2, "Parent navigation selects the folder just left")

let callbackCount = callbacks.count
browser.showDirectory(folder10)
browser.showDirectory(folder2)
waitFor("Latest navigation completes") { !browser.isLoading }
expect(browser.directoryURL == folder2 && browser.mediaFiles.map(\.url) == [nestedFile],
       "Old directory results never replace a newer navigation")
expect(callbacks.count == callbackCount + 1 && callbacks.last?.0 == folder2,
       "Stale completions do not notify the host")
let beforeCancel = callbacks.count
browser.showDirectory(directory)
browser.cancelPendingLoads()
pump(0.2)
expect(!browser.isLoading && callbacks.count == beforeCancel, "Cancelled loads do not publish results")
browser.showDirectory(directory)
waitFor("Cancelled directory can be retried without force") { !browser.isLoading }
expect(browser.mediaFiles.count == 3, "Retry after cancellation repopulates files")

let beforeError = callbacks.count
browser.showDirectory(root.appendingPathComponent("Missing"))
waitFor("Missing directory finishes with an error") { !browser.isLoading }
expect(browser.loadError != nil && !browser.statusLabel.isHidden, "Directory errors are visible")
try capture(browser, name: "directory-error")
expect(callbacks.count == beforeError, "Failed directory does not publish a misleading empty snapshot")
browser.showDirectory(folder10)
waitFor("Empty directory loads") { !browser.isLoading }
expect(browser.loadError == nil && browser.visibleEntries.isEmpty && !browser.statusLabel.isHidden,
       "An empty directory displays an explicit empty state")
expect(callbacks.last?.0 == folder10 && callbacks.last?.1.isEmpty == true, "Successful empty folder publishes an empty snapshot")

browser.showDirectory(directory)
waitFor("Copy source directory loads") { !browser.isLoading }
let copiedRows = IndexSet(browser.visibleEntries.indices.filter { [file2, file10].contains(browser.visibleEntries[$0].url) })
browser.tableView.selectRowIndexes(copiedRows, byExtendingSelection: false)
browser.refresh()
waitFor("Multi-selection refresh completes") { !browser.isLoading }
expect(browser.tableView.selectedRowIndexes == copiedRows, "Refresh preserves multi-selection by file identity")
let unrelatedRevision = browser.mediaFilesRevision
NotificationCenter.default.post(name: .playbackFileTagsChanged, object: nil, userInfo: ["url": nestedFile])
expect(browser.mediaFilesRevision == unrelatedRevision && !browser.isLoading,
       "A tag change in an unrelated folder does not trigger a scan")
try setTags(["New red tag\n6"], at: file10)
NotificationCenter.default.post(name: .playbackFileTagsChanged, object: nil, userInfo: ["url": file10])
waitFor("The matching tag notification preserves a multi-selection") { !browser.isLoading }
expect(browser.tableView.selectedRowIndexes == copiedRows, "Tag metadata refresh preserves selected files")
browser.tagFilterControls.filterPopup.selectItem(at: 1)
send(browser.tagFilterControls.filterPopup)
expect(browser.visibleEntries.filter { !$0.isDirectory }.map(\.url) == [file10],
       "The color filter sees the newly applied Finder tag")
try setTags(["Review red\n6"], at: file2)
NotificationCenter.default.post(name: .playbackFileTagsChanged, object: nil, userInfo: ["url": file2])
waitFor("An active color filter updates immediately after a tag notification") { !browser.isLoading }
expect(Set(browser.visibleEntries.filter { !$0.isDirectory }.map(\.url)) == Set([file2, file10]),
       "A matching tag edit updates the visible filtered files")
browser.tagFilterControls.filterPopup.selectItem(at: 0)
send(browser.tagFilterControls.filterPopup)
browser.tableView.selectRowIndexes(copiedRows, byExtendingSelection: false)
window.makeFirstResponder(browser.tableView)
browser.tableView.copy(nil)
let destinationBrowser = MediaFolderBrowserView(extensions: ["png", "mp4"], pasteboard: filePasteboard)
let destinationWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 540),
                                styleMask: [.titled], backing: .buffered, defer: false)
destinationWindow.contentView = destinationBrowser
destinationWindow.orderFront(nil)
destinationBrowser.showDirectory(folder10)
waitFor("Copy destination loads") { !destinationBrowser.isLoading }
destinationWindow.makeFirstResponder(destinationBrowser.tableView)
destinationBrowser.tableView.paste(nil)
waitFor("Native multi-file paste refreshes destination") {
  MediaFileActions.pendingOperationCount == 0 && !destinationBrowser.isLoading && destinationBrowser.mediaFiles.count == 2
}
let pastedBytes = try Data(contentsOf: folder10.appendingPathComponent("2.png"))
let sourceBytes = try Data(contentsOf: file2)
expect(pastedBytes == sourceBytes,
       "File-table copy preserves source bytes")
expect(FileManager.default.fileExists(atPath: file2.path), "Copy retains the original")
destinationBrowser.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
let moving = destinationBrowser.visibleEntries[0].url
destinationBrowser.tableView.cut(nil)
expect(FileManager.default.fileExists(atPath: moving.path), "Cut alone never deletes files")
browser.showDirectory(folder2)
waitFor("Move destination loads") { !browser.isLoading }
window.makeFirstResponder(browser.tableView)
browser.tableView.paste(nil)
waitFor("Cut paste refreshes both folder windows") {
  MediaFileActions.pendingOperationCount == 0 && !browser.isLoading && !destinationBrowser.isLoading &&
    destinationBrowser.mediaFiles.count == 1 && browser.mediaFiles.count == 2
}
expect(!FileManager.default.fileExists(atPath: moving.path) &&
       FileManager.default.fileExists(atPath: folder2.appendingPathComponent(moving.lastPathComponent).path),
       "Cut paste moves the actual file and removes its old listing")
expect(UpdateWorkAdmission.shared.activeReasons.isEmpty, "Completed transfers release the update activity lease")
let alias = root.appendingPathComponent("MediaAlias", isDirectory: true)
try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
let aliasSource = try file("Media/alias-refresh.png")
browser.showDirectory(directory)
waitFor("The canonical browser loads an alias transfer source") {
  !browser.isLoading && browser.visibleEntries.contains { $0.url == aliasSource }
}
let aliasReport = MediaFileTransfer.execute(
  sources: [try MediaFileTransfer.Source(url: alias.appendingPathComponent(aliasSource.lastPathComponent))],
  destination: try MediaFileTransfer.Source(url: folder2), operation: .move)
expect(aliasReport.successes.count == 1, "Moving through a parent alias succeeds")
NotificationCenter.default.post(name: .mediaFilesTransferred, object: nil,
  userInfo: ["report": aliasReport, "operation": MediaFileTransfer.Operation.move])
waitFor("An alias transfer refreshes the canonical source listing") {
  !browser.isLoading && !browser.visibleEntries.contains { $0.url == aliasSource }
}
destinationWindow.orderOut(nil)
window.orderOut(nil)
if ProcessInfo.processInfo.environment["CHENGYING_PERFORMANCE_BENCHMARK"] == "1" {
  let performanceDirectory = try folder("Performance")
  for index in 0..<10_000 {
    _ = try file("Performance/Image \((index * 7919) % 10_000).png")
  }
  let performanceBrowser = MediaFolderBrowserView(extensions: ["png"])
  performanceBrowser.showDirectory(performanceDirectory)
  waitFor("Synthetic performance directory loads") { !performanceBrowser.isLoading }
  expect(performanceBrowser.mediaFiles.count == 10_000, "Performance fixture contains every generated file")
  let input = (0..<10_000).map {
    MediaFolderBrowserView.Entry(metadata: performanceBrowser.mediaFiles[($0 * 7919) % 10_000], isDirectory: false)
  }
  let revision = performanceBrowser.mediaFilesRevision
  var referenceTimes: [Double] = []
  var currentTimes: [Double] = []
  for filter in [PlaylistTagFilter.all, .untagged, .color(6), .all, .untagged] {
    let referenceStart = CACurrentMediaTime()
    // The previous presentation path sorted the complete snapshot for every filter.
    let files = input.filter { !$0.isDirectory }
    let sorted = PlaylistFileMetadata.sortedIndices(for: files.map(\.metadata)).map { files[$0] }
    let expected = sorted.filter { filter.includes($0.metadata) }
    referenceTimes.append((CACurrentMediaTime() - referenceStart) * 1000)
    let currentStart = CACurrentMediaTime()
    performanceBrowser.tagFilterControls.onFilterChange?(filter)
    currentTimes.append((CACurrentMediaTime() - currentStart) * 1000)
    expect(performanceBrowser.visibleEntries == expected,
           "Cached production filtering preserves the reference presentation for \(filter)")
    expect(performanceBrowser.mediaFilesRevision == revision, "Repeated filters never invalidate complete media order")
  }
  print(String(format: "PERF folder-filter count=10000 reference_median_ms=%.3f current_median_ms=%.3f",
               referenceTimes.sorted()[2], currentTimes.sorted()[2]))
}
print("Media folder browser checks passed: \(checks)")
