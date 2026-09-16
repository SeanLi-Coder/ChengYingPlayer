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

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chengying-playlist-operations-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let large = directory.appendingPathComponent("Episode 10.mp4")
let small = directory.appendingPathComponent("Episode 2.mp4")
let replacement = directory.appendingPathComponent("Replacement.mp4")
try Data(repeating: 1, count: 1024).write(to: large)
try Data(repeating: 2, count: 16).write(to: small)
try Data(repeating: 3, count: 32).write(to: replacement)

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
      abs(scrollView.frame.maxY - controller.sortControls.frame.minY) < 0.5,
      "The actual sort toolbar reserves its own row above the playlist without overlapping the scroll view")

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
