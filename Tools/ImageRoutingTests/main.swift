import Cocoa

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) {
  guard condition() else { fatalError("FAIL: \(description)") }
  checks += 1
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("ImageRoutingTests-\(UUID().uuidString)").resolvingSymlinksInPath()
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
func file(_ name: String, in folder: URL = root) throws -> URL {
  let url = folder.appendingPathComponent(name)
  try Data("fixture".utf8).write(to: url)
  return url
}
let first = try file("Image 2.PNG")
let second = try file("Image 10.gif")
let video = try file("Movie.mp4")
let audio = try file("Music.mp3")
let subtitle = try file("Movie.srt")
let hidden = try file(".hidden.jpg")
let nested = root.appendingPathComponent("Nested", isDirectory: true)
try fm.createDirectory(at: nested, withIntermediateDirectories: true)
_ = try file("Nested.webp", in: nested)
let remote = URL(string: "https://example.invalid/image.jpg")!
func plan(_ urls: [URL]) -> ImageOpenPlan { ImageOpenPlan.make(urls, playbackExtensions: ["mp4", "mkv", "mp3", "flac"]) }

check(plan([first, video, second]).imageURLs == [first, second], "Explicit image order is stable across mixed selections")
check(plan([first, video, second]).mediaURLs == [video], "Image selection cannot enter the video playlist")
check(plan([video, audio, subtitle]).mediaURLs == [video, audio, subtitle], "Routing preserves existing video, audio, and subtitle handling")
check(plan([remote]).imageURLs.isEmpty && plan([remote]).mediaURLs == [remote], "Remote image URLs remain subject to the local-media gate")
check(plan([root]).imageURLs == [first, second], "Folder image discovery is shallow, visible, and naturally sorted")
check(plan([root]).mediaURLs == [root], "Mixed folders retain the original video folder-autoload semantics")
check(plan([root]).browserDirectoryURL == root, "A single mixed folder retains its browser location")
check(plan([first, second]).browserDirectoryURL == nil, "Explicit image selections never become folder selections")
check(!plan([root]).imageURLs.contains(hidden), "Hidden folder entries are not automatically opened")
check(plan([first, root, second]).imageURLs == [first, second], "Explicit files and folder discovery share stable image deduplication")
let alias = root.appendingPathComponent("Alias.png")
try fm.createSymbolicLink(at: alias, withDestinationURL: first)
check(plan([first, alias]).imageURLs == [first], "Symlink aliases do not create duplicate image entries")
check(plan([nested]).mediaURLs.isEmpty && plan([nested]).imageCount == 1, "Image-only folders never start an empty video player")
let container = root.appendingPathComponent("Container", isDirectory: true)
try fm.createDirectory(at: container.appendingPathComponent("Subfolder", isDirectory: true), withIntermediateDirectories: true)
let containerPlan = plan([container])
check(containerPlan.imageURLs.isEmpty && containerPlan.mediaURLs.isEmpty && containerPlan.browserDirectoryURL == container,
      "A folder containing only subfolders opens a browser without an empty media player")
check(containerPlan.hasImageViewerInput && containerPlan.combinedCount(with: 0) == 1,
      "A successful folder browser opening is counted even before an image is selected")
let album = root.appendingPathComponent("Album", isDirectory: true)
try fm.createDirectory(at: album, withIntermediateDirectories: true)
let cover = try file("cover.jpg", in: album)
_ = try file("track.mp3", in: album)
check(plan([album]).imageURLs == [cover] && plan([album]).mediaURLs == [album],
      "Album artwork does not consume a folder that still contains audio media")
let missing = root.appendingPathComponent("Missing", isDirectory: true)
check(plan([missing]).imageURLs.isEmpty, "Missing directories are safely left to existing open-error handling")
check(plan([first]).combinedCount(with: 0) == 1, "A successful image opening is not reported as nothing to open")
check(plan([first]).combinedCount(with: nil) == 1, "A handled disc or playlist plus an image retains image success")
check(plan([video]).combinedCount(with: nil) == nil, "Video-only handled-folder nil semantics remain unchanged")
check(plan([first, second]).combinedCount(with: 3) == 5, "Mixed opening counts include both media types")
let disc = root.appendingPathComponent("Disc", isDirectory: true)
let bdmv = disc.appendingPathComponent("BDMV", isDirectory: true)
try fm.createDirectory(at: bdmv, withIntermediateDirectories: true)
_ = try file("MovieObject.bdmv", in: bdmv)
_ = try file("index.bdmv", in: bdmv)
_ = try file("cover.jpg", in: disc)
check(plan([disc]).imageURLs.isEmpty && plan([disc]).mediaURLs == [disc], "Disc artwork does not intercept Blu-ray folder playback")

let coordinator = ImageViewerCoordinator.shared
check(!coordinator.isBusy, "The image subsystem starts idle")
let opened = coordinator.openImages(in: [first])
check(opened.mediaURLs.isEmpty && opened.imageCount == 1, "The actual coordinator exposes the routed opening result")
check(ImageViewerWindowController.instances.count == 1, "A pure-image action creates exactly one retained viewer")
let viewer = ImageViewerWindowController.instances[0]
check(viewer.window?.isVisible == true, "The coordinator presents the native image window")
check(coordinator.hasOpenedImages, "Image-only launches participate in the user's quit-after-last-window setting")
let videoWindow = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 300, height: 200),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
videoWindow.isReleasedWhenClosed = false
let videoController = PlayerWindowController(window: videoWindow)
let panel = NSPanel()
check(ImageViewerCoordinator.blocksPlaybackMenu(keyWindow: viewer.window, mainWindow: videoWindow),
      "An image key window cannot modify a video left behind as main window")
check(ImageViewerCoordinator.blocksPlaybackMenu(keyWindow: nil, mainWindow: viewer.window),
      "An image main window blocks app-level playback selectors without a key window")
check(ImageViewerCoordinator.blocksPlaybackMenu(keyWindow: panel, mainWindow: viewer.window),
      "An auxiliary panel does not expose the image window's background video controls")
check(!ImageViewerCoordinator.blocksPlaybackMenu(keyWindow: videoWindow, mainWindow: viewer.window),
      "A genuine video key window retains device control during a main-window transition")
check(!ImageViewerCoordinator.blocksPlaybackMenu(keyWindow: nil, mainWindow: videoWindow),
      "An ordinary video main window retains its audio-device menu")
check(!ImageViewerCoordinator.blocksPlaybackMenu(keyWindow: nil, mainWindow: nil),
      "Unrelated app-level menu behavior remains unchanged without an image context")
let imageSheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                          styleMask: [.titled], backing: .buffered, defer: false)
imageSheet.isReleasedWhenClosed = false
viewer.window!.beginSheet(imageSheet)
check(imageSheet.sheetParent === viewer.window,
      "Sheet isolation uses a real AppKit parent relationship")
check(ImageViewerCoordinator.blocksPlaybackMenu(keyWindow: imageSheet, mainWindow: videoWindow),
      "An image confirmation sheet cannot change the background video's device")
viewer.window!.endSheet(imageSheet)
imageSheet.orderOut(nil)
let videoSheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                          styleMask: [.titled], backing: .buffered, defer: false)
videoSheet.isReleasedWhenClosed = false
videoController.showWindow(nil)
videoWindow.beginSheet(videoSheet)
check(!ImageViewerCoordinator.blocksPlaybackMenu(keyWindow: videoSheet, mainWindow: viewer.window),
      "A genuine video sheet resolves to its video owner rather than a stale image main window")
videoWindow.endSheet(videoSheet)
videoSheet.orderOut(nil)
videoController.close()
check(PlayerCore.playerCores[0].initialWindow.closeCount == 1, "Welcome is closed only after the image replacement is visible")
_ = coordinator.openImages(in: [second])
check(ImageViewerWindowController.instances.count == 1 && viewer.inputs == [[first], [second]], "Subsequent opening reuses the retained viewer")
_ = coordinator.openImages(in: [container])
check(viewer.inputs.last?.isEmpty == true && viewer.directories.last! == container,
      "The actual coordinator forwards an empty folder browser input to the existing window")
_ = coordinator.openImages(in: [nested])
check(viewer.directories.last! == nested && viewer.inputs.last == plan([nested]).imageURLs,
      "The actual coordinator preserves the image folder context rather than treating it as explicit selection")
viewer.isBusy = true
check(coordinator.isBusy, "Image conversion keeps the app alive when its windows close")
viewer.isBusy = false
viewer.close()
_ = coordinator.openImages(in: [first])
check(viewer.window?.isVisible == true && ImageViewerWindowController.instances.count == 1, "A closed viewer can be opened again without retaining duplicate windows")
coordinator.cancelAndClose()
check(viewer.cancelCount == 1 && !coordinator.isBusy, "Application shutdown cancels the viewer's own work and releases it")
coordinator.cancelAndClose()
_ = coordinator.openImages(in: [second])
check(viewer.cancelCount == 1 && ImageViewerWindowController.instances.count == 1, "Shutdown is idempotent and forbids late reopening")

let project = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func source(_ name: String) throws -> String {
  try String(contentsOf: project.appendingPathComponent("iina/\(name)"), encoding: .utf8)
}
let player = try source("PlayerCore.swift")
check(player.components(separatedBy: "ImageViewerCoordinator.shared.openImages").count == 3,
      "Both static and instance public player opening boundaries route images")
check(player.contains("guard Utility.isLocalPlaybackPath(path)") && player.contains("paths.filter(Utility.isLocalPlaybackPath)"),
      "Both playlist append APIs exclude image paths, including URL scheme and paste inputs")
let utility = try source("Utility.swift")
let videoDeclaration = utility.components(separatedBy: ".video: [")[1].components(separatedBy: "],")[0]
check(!videoDeclaration.contains("\"gif\""), "GIF no longer appears in production automatic video extension lists")
check(utility.contains("Array(ImageFileSupport.extensions)"), "All viewer image extensions are blacklisted from explicit video playlists")
let plistData = try Data(contentsOf: project.appendingPathComponent("iina/Info.plist"))
let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as! [String: Any]
let documentTypes = plist["CFBundleDocumentTypes"] as! [[String: Any]]
let imagesType = documentTypes.first { $0["CFBundleTypeName"] as? String == "Image" }!
check(Set(imagesType["CFBundleTypeExtensions"] as! [String]) == ImageFileSupport.extensions,
      "Finder image document declarations match the actual production routing extensions exactly")
check(imagesType["LSHandlerRank"] as? String == "Alternate", "Image support never silently replaces the user's default image application")
check(plist["CFBundleName"] as? String == "ChengYing", "The existing bundle and CLI executable identity remains compatible")
let app = try source("AppDelegate.swift")
check(app.contains("guard !ImageViewerCoordinator.shared.isBusy else { return false }"), "The real application auto-quit guard includes image work")
check(app.contains("if imagePlan?.mediaURLs.isEmpty == true { return }"), "Image-only URL scheme requests return before enqueue and PIP handling")
check(app.contains("else if !plan.mediaURLs.isEmpty"), "Image-only CLI requests never create an empty player")
let audioAction = app.components(separatedBy: "func menuSelectAudioDevice(")[1].components(separatedBy: "@IBAction")[0]
check(audioAction.contains("guard !ImageViewerCoordinator.blocksPlaybackMenu else { return }"),
      "The production audio-device selector applies the tested image-window guard")
let menu = try source("MenuController.swift")
let audioMenu = menu.components(separatedBy: "private func updateAudioDevice()")[1].components(separatedBy: "private func")[0]
check(audioMenu.contains("guard !ImageViewerCoordinator.blocksPlaybackMenu") && audioMenu.contains("action: nil") && audioMenu.contains("item.isEnabled = false"),
      "The production audio-device menu shows a disabled entry instead of clickable background-device actions")
let downloader = try source("DownloadCenter/DownloadCenterWindowController.swift")
check(downloader.contains("PlayerCore.openURLs([url])") && !downloader.contains("PlayerCore.activeOrNew.openURL"),
      "Download output opening reaches the static router before any player is selected or allocated")
print("Image routing checks passed: \(checks)")
