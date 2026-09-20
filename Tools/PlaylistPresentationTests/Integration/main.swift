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
func drain(until condition: () -> Bool, message: String) {
  let deadline = Date().addingTimeInterval(5)
  while !condition() && Date() < deadline {
    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
  check(condition(), message)
}
func items(_ urls: [URL], firstID: Int64 = 1) -> [MPVPlaylistItem] {
  let ids = urls.indices.map { firstID + Int64($0) }
  return urls.enumerated().map { index, url in
    MPVPlaylistItem(filename: url.path, isCurrent: index == 0, isPlaying: index == 0,
                    title: nil, entryID: ids[index], snapshotEntryIDs: ids)
  }
}
func setPlaylist(_ controller: PlaylistControllerUnderTest, _ playlist: [MPVPlaylistItem]) {
  controller.player.backendPlaylist = playlist
  controller.player.getPlaylist()
}
func normalizedURLs(_ urls: [URL]) -> [URL] {
  urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
}

let directory = FileManager.default.temporaryDirectory
  .appendingPathComponent("chengying-playlist-operations-\(UUID().uuidString)").resolvingSymlinksInPath()
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let large = directory.appendingPathComponent("Episode 10.mp4")
let small = directory.appendingPathComponent("Episode 2.mp4")
let replacement = directory.appendingPathComponent("Replacement.mp4")
try Data(repeating: 1, count: 1024).write(to: large)
try Data(repeating: 2, count: 16).write(to: small)
try Data(repeating: 3, count: 32).write(to: replacement)
let nestedDirectory = directory.appendingPathComponent("Season 2", isDirectory: true)
try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
let nestedVideo = nestedDirectory.appendingPathComponent("Episode 1.mp4")
let imageFixture = nestedDirectory.appendingPathComponent("Cover.png")
try Data([1, 2, 3]).write(to: nestedVideo)
try Data([4, 5, 6]).write(to: imageFixture)

let controller = PlaylistControllerUnderTest()
let playback = PlayerCore()
controller.player = playback
controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 435))
setPlaylist(controller, items([large, small]))
controller.requestSort(key: .size, ascending: true)
check(controller.metadataLoading && !controller.sortControls.refreshButton.isEnabled,
      "Real controller enters the busy state for metadata-backed sorting")
// Finish the worker without servicing the main queue. Its completion must keep
// the finished BlockOperation alive until its queued main-thread callback runs.
controller.metadataQueue.waitUntilAllOperationsAreFinished()
drain(until: { !controller.metadataLoading }, message: "Finished real BlockOperation survives until its main-thread completion")
check(controller.player.info.playlist.map(\.filename) == [small.path, large.path],
      "Metadata completion sorts actual file sizes through the playback boundary")
check(controller.pendingSortIDs == nil && controller.sortControls.refreshButton.isEnabled,
      "Completed metadata sorting clears the pending identity list and busy state")
check(controller.fileMetadata[large.path]?.fileSize == 1024 && controller.fileMetadata[small.path]?.fileSize == 16,
      "The controller caches results from real on-disk metadata reads")

setPlaylist(controller, items([large, small]))
controller.refreshFileMetadata(force: true)
controller.metadataQueue.waitUntilAllOperationsAreFinished()
setPlaylist(controller, items([replacement], firstID: 50))
controller.refreshFileMetadata(force: true)
controller.metadataQueue.waitUntilAllOperationsAreFinished()
drain(until: { !controller.metadataLoading }, message: "A newer generation completes after an older callback has already been queued")
check(Set(controller.fileMetadata.keys) == [replacement.path] && controller.metadataPaths == [replacement.path],
      "A stale queued generation cannot overwrite the new playlist metadata")

let original = items([large, small])
setPlaylist(controller, original)
controller.metadataQueue.isSuspended = true
controller.requestSort(key: .size, ascending: true)
let reorderCount = controller.player.reorderCount
// Keep info stale, just as a manual mpv mutation can precede the debounced reload.
controller.player.backendPlaylist = original.reversed()
controller.metadataQueue.isSuspended = false
controller.metadataQueue.waitUntilAllOperationsAreFinished()
drain(until: { !controller.metadataLoading }, message: "A pending metadata operation finishes after external manual reordering")
check(controller.player.reorderCount == reorderCount && controller.player.info.playlist.map(\.entryID) == original.reversed().map(\.entryID),
      "A changed entry-ID order cancels pending sort application instead of undoing manual reordering")

setPlaylist(controller, original)
controller.metadataQueue.isSuspended = true
controller.requestSort(key: .size, ascending: false)
controller.requestSort(key: .name, ascending: true)
let nameReorderCount = controller.player.reorderCount
controller.metadataQueue.isSuspended = false
controller.metadataQueue.waitUntilAllOperationsAreFinished()
drain(until: { !controller.metadataLoading }, message: "Metadata completion remains safe after switching immediately to name sorting")
check(controller.player.reorderCount == nameReorderCount && controller.player.info.playlist.map(\.filename) == [small.path, large.path],
      "An obsolete metadata sort cannot overwrite a newer immediate natural-name sort")

let duplicates = items([large, large])
setPlaylist(controller, duplicates)
controller.requestSort(key: .size, ascending: true)
let duplicateReorderCount = controller.player.reorderCount
controller.metadataQueue.waitUntilAllOperationsAreFinished()
drain(until: { !controller.metadataLoading }, message: "Repeated filenames complete metadata sorting normally")
check(controller.fileMetadata.count == 1 && controller.player.info.playlist.map(\.entryID) == duplicates.map(\.entryID) &&
      controller.player.reorderCount == duplicateReorderCount + 1,
      "Deduplicated filesystem reads preserve both distinct playlist entry identities")

setPlaylist(controller, original)
controller.requestSort(key: .size, ascending: false)
controller.metadataQueue.waitUntilAllOperationsAreFinished()
let cancelledReadCount = controller.player.snapshotReads
let cancelledSortCount = controller.player.reorderCount
controller.cancelMetadataRefresh()
_ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
check(controller.fileMetadata.isEmpty && controller.player.snapshotReads == cancelledReadCount &&
      controller.player.reorderCount == cancelledSortCount,
      "Explicit cancellation rejects a finished worker callback already queued on the main thread")

setPlaylist(controller, original)
controller.requestSort(key: .size, ascending: false)
controller.metadataQueue.waitUntilAllOperationsAreFinished()
controller.player.info.state.active = false
let stoppedReadCount = controller.player.snapshotReads
let stoppedSortCount = controller.player.reorderCount
drain(until: { !controller.metadataLoading }, message: "Playback stopping clears an in-flight metadata operation")
check(controller.player.snapshotReads == stoppedReadCount && controller.player.inactiveReads == 0 &&
      controller.player.reorderCount == stoppedSortCount && controller.pendingSortIDs == nil,
      "Inactive playback is never queried or sorted by a queued completion")
controller.player.info.state.active = true

setPlaylist(controller, original)
let refreshOnlySortCount = controller.player.reorderCount
controller.refreshFileMetadata(force: true)
controller.metadataQueue.waitUntilAllOperationsAreFinished()
drain(until: { !controller.metadataLoading }, message: "A refresh-only operation completes metadata reading")
check(controller.fileMetadata.count == 2 && controller.player.reorderCount == refreshOnlySortCount,
      "Refreshing Finder tags does not change the user's playback order")

setPlaylist(controller, [])
controller.refreshFileMetadata(force: true)
check(controller.fileMetadata.isEmpty && !controller.metadataLoading && controller.pendingSortIDs == nil,
      "An empty playlist clears metadata, pending sorting, and busy state")

controller.installNotifications()
setPlaylist(controller, original)
controller.refreshFileMetadata(force: true)
controller.metadataQueue.waitUntilAllOperationsAreFinished()
let generationBeforeStop = controller.metadataGeneration
NotificationCenter.default.post(name: .iinaPlayerStopped, object: playback)
_ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
check(controller.metadataGeneration > generationBeforeStop && !controller.metadataLoading && controller.fileMetadata.isEmpty,
      "The real stop notification invalidates queued metadata completion")

let scrollView = NSScrollView()
scrollView.translatesAutoresizingMaskIntoConstraints = false
scrollView.documentView = controller.playlistTableView
controller.view.addSubview(scrollView)
let originalTop = scrollView.topAnchor.constraint(equalTo: controller.view.topAnchor)
NSLayoutConstraint.activate([
  originalTop,
  scrollView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
  scrollView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
  scrollView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: 24),
])
controller.installSortControls()
controller.view.layoutSubtreeIfNeeded()
check(!originalTop.isActive, "Installing the actual sort toolbar removes the previous scroll-view top constraint")
check(abs(controller.sortControls.frame.maxY - controller.view.bounds.maxY) < 0.5 &&
      abs(controller.tagFilterControls.frame.maxY - controller.sortControls.frame.minY) < 0.5 &&
      abs(scrollView.frame.maxY - controller.tagFilterControls.frame.minY) < 0.5,
      "The actual sort and filter toolbars reserve separate rows without overlapping the playlist")

controller.installFolderBrowser()
controller.view.layoutSubtreeIfNeeded()
check(controller.folderBrowser.isHidden && !scrollView.isHidden &&
      controller.browserModeControl.selectedSegment == 1 && !controller.browserModeControl.isEnabled(forSegment: 0),
      "A player without a local file keeps the playback queue available and disables folder browsing")
check(controller.browserModeControl.label(forSegment: 0) == playlistBrowserString("browser.files") &&
      controller.browserModeControl.label(forSegment: 1) == playlistBrowserString("browser.queue"),
      "The installed mode switch uses the actual localized browser and playback queue labels")
check(controller.browserModeControl.frame.maxY <= controller.view.bounds.maxY &&
      controller.sortControls.frame.maxY <= controller.browserModeControl.frame.minY &&
      controller.folderBrowser.frame.maxY <= controller.browserModeControl.frame.minY,
      "Both the real queue toolbar and folder browser fit below the separate mode switch")
playback.info.currentURL = large
controller.syncFolderBrowser()
check(!controller.folderBrowser.isHidden && scrollView.isHidden && controller.sortControls.isHidden &&
      controller.tagFilterControls.isHidden && controller.browserModeControl.selectedSegment == 0,
      "The first local playback file defaults to the folder browser without overlapping the queue controls")
controller.browserModeControl.selectedSegment = 1
NSApp.sendAction(controller.browserModeControl.action!, to: controller.browserModeControl.target,
                 from: controller.browserModeControl)
check(controller.folderBrowser.isHidden && !scrollView.isHidden && !controller.sortControls.isHidden &&
      !controller.tagFilterControls.isHidden && !controller.prefersFolderBrowser,
      "The installed native mode callback restores the existing sortable playback queue")

func writeTags(_ names: [String], to url: URL) throws {
  let data = try PropertyListSerialization.data(fromPropertyList: names, format: .binary, options: 0)
  let result = data.withUnsafeBytes { bytes in
    url.withUnsafeFileSystemRepresentation { path in
      setxattr(path!, "com.apple.metadata:_kMDItemUserTags", bytes.baseAddress, bytes.count, 0, 0)
    }
  }
  check(result == 0, "Finder tags are written only to the temporary integration fixture")
}
try writeTags(["Project review\n6", "Shared\n2"], to: large)
try writeTags(["Client\n4"], to: small)
setPlaylist(controller, original)
playback.info.currentURL = large
controller.reloadData(playlist: true, chapters: false)
drain(until: { !controller.metadataLoading }, message: "Initial filter metadata finishes before the real popup action")
let filterReorderCount = playback.reorderCount
controller.tagFilterControls.filterPopup.selectItem(at: PlaylistTagFilter.allCases.firstIndex(of: .color(6))!)
NSApp.sendAction(controller.tagFilterControls.filterPopup.action!, to: controller.tagFilterControls.filterPopup.target,
                 from: controller.tagFilterControls.filterPopup)
check(controller.tagFilter == .color(6) && controller.displayedPlaylist.map(\.filename) == [large.path],
      "The installed native filter callback displays only matching real Finder metadata")
check(playback.reorderCount == filterReorderCount && playback.info.playlist.map(\.entryID) == original.map(\.entryID),
      "Filtering never reorders or removes the underlying playback queue")
controller.requestTagFilter(.color(2))
check(controller.displayedPlaylist.map(\.filename) == [large.path], "A second color of a multi-tag file also matches")
controller.requestTagFilter(.color(3))
check(controller.displayedPlaylist.isEmpty && !controller.filterEmptyLabel.isHidden,
      "A finished zero-match filter exposes the localized empty-list explanation")
controller.requestTagFilter(.all)
check(controller.displayedPlaylist.count == 2 && controller.filterEmptyLabel.isHidden,
      "Clearing the filter restores all entries and removes the empty-result message")

try writeTags(["Changed\n4"], to: large)
try writeTags(["Changed\n6"], to: small)
controller.requestTagFilter(.color(6))
controller.metadataQueue.isSuspended = true
controller.refreshFileMetadata(force: true)
controller.requestTagFilter(.color(4))
controller.metadataQueue.isSuspended = false
drain(until: { !controller.metadataLoading }, message: "Finder retagging refresh completes after changing the active filter")
check(controller.tagFilter == .color(4) && controller.displayedPlaylist.map(\.filename) == [large.path],
      "Queued metadata completion uses the current filter, not the filter at request time")
check(playback.reorderCount == filterReorderCount, "Refreshing tag colors does not change playback order")
controller.requestSort(key: .name, ascending: true)
check(controller.tagFilter == .color(4) && controller.displayedPlaylist.map(\.filename) == [large.path],
      "Sorting the actual playback queue preserves the active color filter")
setPlaylist(controller, items([replacement], firstID: 500))
controller.metadataQueue.isSuspended = true
controller.reloadData(playlist: true, chapters: false)
check(controller.tagFilter == .all && controller.displayedPlaylist.map(\.filename) == [replacement.path],
      "A completely replaced queue clears the old folder's filter")
controller.requestTagFilter(.untagged)
check(controller.displayedPlaylist.isEmpty && controller.filterEmptyLabel.isHidden,
      "Unknown metadata is not temporarily classified as untagged while loading")
controller.metadataQueue.isSuspended = false
drain(until: { !controller.metadataLoading }, message: "New folder tag metadata finishes")
check(controller.displayedPlaylist.map(\.filename) == [replacement.path],
      "Confirmed untagged files appear once the metadata read finishes")
controller.cancelMetadataRefresh()
check(controller.displayedPlaylist.isEmpty && controller.filterEmptyLabel.isHidden,
      "Stopping metadata work clears stale filtered rows")

setPlaylist(controller, original)
playback.info.currentURL = large
controller.syncFolderBrowser()
check(controller.folderBrowser.isHidden && controller.browserModeControl.selectedSegment == 1,
      "A playback refresh preserves the user's explicit playback queue mode")
controller.browserModeControl.selectedSegment = 0
NSApp.sendAction(controller.browserModeControl.action!, to: controller.browserModeControl.target,
                 from: controller.browserModeControl)
check(!controller.folderBrowser.isHidden && controller.prefersFolderBrowser && controller.filterEmptyLabel.isHidden,
      "Returning to folder browsing removes any playback filter empty-state overlay")
let folderQueueIDs = playback.backendPlaylist.map(\.entryID)
let folderReorderCount = playback.reorderCount
let browser = controller.folderBrowser
drain(until: { !browser.isLoading }, message: "The installed browser finishes reading the current playback folder")
func activateBrowserEntry(_ url: URL) {
  guard let row = browser.visibleEntries.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else {
    fatalError("Expected fixture entry is missing from the production folder browser: \(url.lastPathComponent)")
  }
  browser.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
  NSApp.sendAction(browser.tableView.doubleAction!, to: browser.tableView.target, from: browser.tableView)
}
activateBrowserEntry(nestedDirectory)
drain(until: { !browser.isLoading }, message: "The real browser row action opens the selected direct child folder")
check(browser.directoryURL == nestedDirectory.standardizedFileURL && playback.openedURLs.isEmpty &&
      ImageViewerCoordinator.shared.openedURLGroups.isEmpty,
      "Entering a child folder browses its files without opening media or replacing playback")
controller.reloadData(playlist: true, chapters: false)
NotificationCenter.default.post(name: .iinaFileLoaded, object: playback)
check(browser.directoryURL == nestedDirectory.standardizedFileURL,
      "Queue reloads and repeated file-loaded notifications preserve the user's manually browsed folder")
activateBrowserEntry(imageFixture)
check(ImageViewerCoordinator.shared.openedURLGroups.map(normalizedURLs) == [normalizedURLs([imageFixture])] &&
      playback.openedURLs.isEmpty,
      "Opening an image through the installed folder callback reaches only the image viewer boundary")
activateBrowserEntry(nestedVideo)
check(normalizedURLs(playback.openedURLs) == normalizedURLs([nestedVideo]) &&
      ImageViewerCoordinator.shared.openedURLGroups.map(normalizedURLs) == [normalizedURLs([imageFixture])],
      "Opening a video through the installed folder callback reaches the existing playback window")
check(playback.backendPlaylist.map(\.entryID) == folderQueueIDs && playback.reorderCount == folderReorderCount,
      "Folder mode changes and media routing do not sort or mutate the current playback queue")
playback.info.currentURL = small
NotificationCenter.default.post(name: .iinaFileLoaded, object: playback)
drain(until: { !browser.isLoading }, message: "A changed playback URL follows its containing folder")
check(browser.directoryURL == directory.standardizedFileURL && browser.tableView.selectedRow >= 0 &&
      browser.visibleEntries[browser.tableView.selectedRow].url.standardizedFileURL == small.standardizedFileURL,
      "A changed playback file resets the browser to its containing folder and selects that exact file")
let updateOwner = UUID()
check(UpdateWorkAdmission.shared.acquire(updateOwner), "The integration fixture can reserve an idle update admission lock")
check(controller.folderBrowser.canNavigate?() == false,
      "Folder navigation honors the real update admission lock")
controller.folderBrowser.onOpenFile?(large)
controller.folderBrowser.onOpenFile?(imageFixture)
check(normalizedURLs(playback.openedURLs) == normalizedURLs([nestedVideo]) &&
      ImageViewerCoordinator.shared.openedURLGroups.map(normalizedURLs) == [normalizedURLs([imageFixture])],
      "An admitted update blocks both image and video opening through already installed callbacks")
UpdateWorkAdmission.shared.release(updateOwner)
check(controller.folderBrowser.canNavigate?() == true, "Releasing update admission restores folder navigation")
playback.info.state.active = false
check(controller.folderBrowser.canNavigate?() == false, "Stopped playback cannot navigate its obsolete folder browser")
controller.folderBrowser.onOpenFile?(large)
controller.folderBrowser.onOpenFile?(imageFixture)
check(normalizedURLs(playback.openedURLs) == normalizedURLs([nestedVideo]) &&
      ImageViewerCoordinator.shared.openedURLGroups.map(normalizedURLs) == [normalizedURLs([imageFixture])],
      "Stopped playback cannot open new media from stale folder callbacks")
playback.info.state.active = true
playback.info.currentURL = URL(string: "https://example.invalid/media.mp4")!
NotificationCenter.default.post(name: .iinaFileLoaded, object: playback)
check(controller.browserPlaybackURL == nil && controller.folderBrowser.isHidden && !scrollView.isHidden &&
      controller.browserModeControl.selectedSegment == 1 && !controller.browserModeControl.isEnabled(forSegment: 0),
      "The real file-loaded notification falls back to the queue for network media")
playback.info.currentURL = small
NotificationCenter.default.post(name: .iinaFileLoaded, object: playback)
check(controller.browserPlaybackURL == small.standardizedFileURL && !controller.folderBrowser.isHidden &&
      controller.browserModeControl.selectedSegment == 0 && controller.browserModeControl.isEnabled(forSegment: 0),
      "Returning to local playback restores the user's prior folder mode preference")
browser.showDirectory(nestedDirectory, force: true)
check(browser.isLoading, "An explicit folder refresh starts cancellable background work")
playback.info.state.active = false
NotificationCenter.default.post(name: .iinaPlayerStopped, object: playback)
check(!browser.isLoading, "The production stop notification cancels in-flight folder loading immediately")
_ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
check(browser.visibleEntries.isEmpty && !browser.isLoading,
      "A cancelled folder completion cannot repopulate rows after playback stops")
playback.info.state.active = true
NotificationCenter.default.post(name: .iinaFileLoaded, object: playback)
drain(until: { !browser.isLoading }, message: "Reopening the same playback file can finish a fresh folder load")
check(browser.directoryURL == directory.standardizedFileURL && !browser.visibleEntries.isEmpty,
      "Reopening the same URL after stop restores browsing instead of retaining a cancelled empty snapshot")
browser.showDirectory(nestedDirectory, force: true)
NotificationCenter.default.post(name: .iinaPlayerShutdown, object: playback)
check(!browser.isLoading, "The production shutdown notification also cancels pending folder work")

var disposableController: PlaylistControllerUnderTest? = PlaylistControllerUnderTest()
disposableController!.player = playback
let disposableQueue = disposableController!.metadataQueue
disposableQueue.isSuspended = true
disposableController!.refreshFileMetadata(force: true)
weak var releasedController = disposableController
disposableController = nil
check(releasedController == nil, "A queued metadata operation does not retain its controller")
check(disposableQueue.operations.allSatisfy(\.isCancelled), "Real controller deinitialization cancels outstanding metadata work")
disposableQueue.isSuspended = false
disposableQueue.waitUntilAllOperationsAreFinished()

final class CellCanvas: NSView {
  override func draw(_ dirtyRect: NSRect) {
    ChengYingStyle.surface.setFill()
    dirtyRect.fill()
  }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let cell = try makeProductionCell(xib: root.appendingPathComponent("iina/Base.lproj/PlaylistViewController.xib"))
let tags = [PlaylistFileTag(name: "Project review", colorIndex: 6), PlaylistFileTag(name: "已完成", colorIndex: 2)]
let tagList = cell.subviews.compactMap { $0 as? PlaylistTagListView }.first!
let oldToken = cell.configure(entryID: 11, tags: tags)
cell.durationLabel.stringValue = "02:13:44"
cell.playbackProgressView.percentage = 0.8
cell.setAdditionalInfo("Previous artist")
let newToken = cell.configure(entryID: 12, tags: [])
check(newToken != oldToken && cell.representedEntryID == 12, "Real cell configuration rotates its asynchronous identity token")
check(cell.durationLabel.stringValue.isEmpty && cell.playbackProgressView.percentage == 0 && cell.infoLabel.stringValue.isEmpty,
      "Reconfiguration resets previous duration, progress, and artist content")
check(tagList.tags.isEmpty && tagList.toolTip == nil && !tagList.isAccessibilityElement(),
      "Reconfiguration clears previous Finder tags and accessibility content")
cell.configure(entryID: 13, tags: tags)
cell.prepareForReuse()
check(cell.representedEntryID == nil && cell.configurationToken != newToken && tagList.tags.isEmpty,
      "Actual prepareForReuse invalidates entry identity and removes all tags")

let canvas = CellCanvas(frame: NSRect(x: 0, y: 0, width: 270, height: 100))
let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 270, height: 100),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = canvas
canvas.addSubview(cell)
cell.configure(entryID: 14, tags: tags)
cell.setPrefix(nil)
cell.setDisplaySubButton(false)
cell.setTitle("Episode 10 · A long original filename.mp4")
cell.durationLabel.stringValue = "02:13:44"
cell.playbackProgressView.percentage = 0.5
let captures = ProcessInfo.processInfo.environment["CHENGYING_CAPTURE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
if let captures { try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true) }
let language = Bundle.main.preferredLocalizations.first ?? "en"
for width in [240, 270, 360, 800] {
  window.setContentSize(NSSize(width: width, height: 100))
  // The playing indicator occupies a separate fixed-width table column.
  cell.frame = NSRect(x: 24, y: 28, width: CGFloat(width - 26), height: 44)
  for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    window.appearance = NSAppearance(named: appearance)
    canvas.layoutSubtreeIfNeeded()
    let title = cell.textField!
    check(!title.hasAmbiguousLayout && !tagList.hasAmbiguousLayout,
          "Actual two-line cell layout is unambiguous at \(width) points in \(theme) mode")
    // NSTextField's drawing frame extends two points beyond its Auto Layout
    // alignment rectangle. Compare the alignment geometry, not that text inset.
    check(cell.bounds.contains(title.alignmentRect(forFrame: title.frame)) && cell.bounds.contains(tagList.frame) &&
          cell.bounds.contains(cell.durationLabel.alignmentRect(forFrame: cell.durationLabel.frame)),
          "Title, duration, and Finder tags remain within the production cell at \(width) points")
    check(tagList.frame.maxY <= title.frame.minY && tagList.frame.minY >= cell.playbackProgressView.frame.maxY,
          "Finder tags do not overlap the original title or playback progress bar at \(width) points")
    guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { fatalError("Missing cell bitmap") }
    canvas.effectiveAppearance.performAsCurrentDrawingAppearance {
      canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
    }
    check(bitmap.pixelsWide >= width, "The actual production cell renders at \(width) points in \(theme) mode")
    if let captures, let png = bitmap.representation(using: .png, properties: [:]) {
      let url = captures.appendingPathComponent("playlist-cell-\(language)-\(theme)-\(width).png")
      try png.write(to: url)
      print("SNAPSHOT: \(url.path)")
    }
  }
}
print("Playlist controller and cell checks passed: \(checks)")
