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

let browser = MediaFolderBrowserView(extensions: ["png", "mp4"])
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

browser.tagFilterControls.filterPopup.selectItem(at: 1)
send(browser.tagFilterControls.filterPopup)
expect(browser.visibleEntries.count == 3 && browser.visibleEntries.last?.url == file2,
       "Red tag filter retains every directory and only matching files")
expect(callbacks.last?.1.map(\.url) == [file2], "Callback exposes visible matching media")
expect(browser.mediaFiles.count == 3, "Unfiltered playback snapshot survives the visual tag filter")
expect(browser.tableView.selectedRow == -1, "Filtered-out selected file is not replaced by another file")
try capture(browser, name: "tag-filter")
browser.tagFilterControls.filterPopup.selectItem(at: 0)
send(browser.tagFilterControls.filterPopup)
expect(browser.visibleEntries[browser.tableView.selectedRow].url == file10, "Clearing filter restores selected file")
try setTags(["Review\n4"], at: file2)
browser.refresh()
waitFor("Refresh finishes") { !browser.isLoading }
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
window.orderOut(nil)
print("Media folder browser checks passed: \(checks)")
