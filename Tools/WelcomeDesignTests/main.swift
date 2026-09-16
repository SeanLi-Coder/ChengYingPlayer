import Cocoa

_ = NSApplication.shared
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}

func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }

check(Bundle.main.bundleIdentifier == "io.github.SeanLi-Coder.ChengYingPlayer.WelcomeDesignTests",
      "KVO tests use a dedicated defaults domain, never the production app domain")
let observedKeys: [Preference.Key] = [.recordRecentFiles, .resumeLastPosition,
                                     .iinaLastPlayedFilePath, .iinaLastPlayedFilePosition]
let savedDefaults = observedKeys.map { ($0.rawValue, UserDefaults.standard.object(forKey: $0.rawValue)) }
defer {
  for (key, previousValue) in savedDefaults {
    if let previousValue { UserDefaults.standard.set(previousValue, forKey: key) }
    else { UserDefaults.standard.removeObject(forKey: key) }
  }
}
UserDefaults.standard.set(true, forKey: Preference.Key.recordRecentFiles.rawValue)
UserDefaults.standard.set(true, forKey: Preference.Key.resumeLastPosition.rawValue)

let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let names = ["Coastline — afternoon light.mov", "城市漫游 · 雨后的街道.mp4", "一段非常长的原始视频文件名_需要完整保留并且能在界面中优雅截断_2026_09_16.mov", "Camping weekend.mp4"]
let files = names.map { temporary.appendingPathComponent("Weekend films").appendingPathComponent($0) }
try FileManager.default.createDirectory(at: files[0].deletingLastPathComponent(), withIntermediateDirectories: true)
for file in files { FileManager.default.createFile(atPath: file.path, contents: Data()) }
Preference.values[.iinaLastPlayedFilePath] = files[0]
Preference.values[.iinaLastPlayedFilePosition] = 84.0
var recent = files + [URL(string: "https://example.invalid/video.mp4")!]
let player = PlayerCore()
let controller = WelcomeHarness(playerCore: player, recentDocumentsProvider: { recent })
let iconPath = Bundle.main.url(forResource: "welcome-icon", withExtension: "png")!
let icon = NSImage(contentsOf: iconPath)!
icon.setName("iina_arrow")
let window = controller.window!
let content = window.contentView!
window.orderFront(nil)
content.layoutSubtreeIfNeeded()
check(controller.loaded, "The production controller builds a native welcome view")
check(controller.recentFilesTableView.tableColumns.count == 1, "Recent files use exactly one native table column")
check(controller.recentDocuments == Array(files.dropFirst()), "Recent files exclude the resume duplicate and network URLs")
check(!controller.resumeButton.isHidden, "An existing last file has a resume action")
check(controller.primaryOpenButton.keyEquivalent == "o", "Open keeps the Command-O shortcut")
controller.primaryOpenButton.performClick(nil)
check(AppDelegate.shared.openedFilePanel, "The primary button opens the existing local file panel")
controller.resumeButton.performClick(nil)
check(player.opened.last == files[0], "Resume uses the existing playback path")
check(!walk(content).compactMap { $0 as? NSButton }.contains { $0.title.contains("URL") },
      "The welcome view does not restore network controls")

func sendKey(_ code: UInt16) {
  controller.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
      charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!)
}
sendKey(125)
check(controller.recentFilesTableView.selectedRow == 0, "Down selects the first recent file")
sendKey(36)
check(player.opened.last == files[1], "Return opens the selected recent file")
sendKey(126)
check(controller.recentFilesTableView.selectedRow == -1, "Up returns to the resume action")
check(controller.resumeButton.state == .on, "The keyboard-selected resume action has visible selection state")

let picture = temporary.appendingPathComponent("Photo.webp")
try Data().write(to: picture)
recent = [picture] + files
controller.reloadData()
controller.recentFilesTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
sendKey(36)
check(player.opened.last == picture, "Recent images use the same image-aware opening boundary as videos")
Preference.values[.iinaLastPlayedFilePath] = picture
controller.reloadData()
check(controller.resumeButton.isHidden, "An old image playback record never displays a fake video resume time")
Preference.values[.iinaLastPlayedFilePath] = files[0]
recent = files
controller.reloadData()
check(window.title == "ChengYing View" || window.title == "澄影视界", "The welcome window uses the visible media-viewer brand")

if let output = ProcessInfo.processInfo.environment["CHENGYING_CAPTURE_DIR"] {
  let directory = URL(fileURLWithPath: output, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let language = Bundle.main.preferredLocalizations.first ?? "en"
  for (theme, appearanceName) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
    for state in ["recent", "empty"] {
      if state == "empty" {
        recent = []
        Preference.values[.iinaLastPlayedFilePath] = nil
      } else {
        recent = files
        Preference.values[.iinaLastPlayedFilePath] = files[0]
      }
      controller.reloadData()
      window.appearance = NSAppearance(named: appearanceName)
      content.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      window.appearance!.performAsCurrentDrawingAppearance {
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
          fatalError("Could not create the native snapshot")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
          fatalError("Could not encode the native snapshot")
        }
        let path = directory.appendingPathComponent("welcome-\(language)-\(theme)-\(state).png")
        try! png.write(to: path)
        print("SNAPSHOT: \(path.path)")
      }
    }
  }
}

recent = files
Preference.values[.iinaLastPlayedFilePath] = files[0]
UserDefaults.standard.set(files[0].absoluteString, forKey: Preference.Key.iinaLastPlayedFilePath.rawValue)
check(!controller.resumeButton.isHidden && !controller.recentDocuments.isEmpty,
      "A real last-file preference notification refreshes the open welcome window")
Preference.values[.resumeLastPosition] = false
UserDefaults.standard.set(false, forKey: Preference.Key.resumeLastPosition.rawValue)
check(controller.resumeButton.isHidden && !controller.recentDocuments.isEmpty,
      "Disabling resume immediately removes its card without hiding recent files")
Preference.values[.resumeLastPosition] = true
UserDefaults.standard.set(true, forKey: Preference.Key.resumeLastPosition.rawValue)
check(!controller.resumeButton.isHidden, "Re-enabling resume immediately restores its card")
Preference.values[.iinaLastPlayedFilePath] = nil
UserDefaults.standard.removeObject(forKey: Preference.Key.iinaLastPlayedFilePath.rawValue)
check(controller.resumeButton.isHidden, "Clearing the last-file preference immediately removes its card")
Preference.values[.iinaLastPlayedFilePath] = files[0]
UserDefaults.standard.set(files[0].absoluteString, forKey: Preference.Key.iinaLastPlayedFilePath.rawValue)
check(!controller.resumeButton.isHidden, "The privacy test starts with a visible resume card")
Preference.values[.recordRecentFiles] = false
let preferenceWrite = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
  UserDefaults.standard.set(false, forKey: Preference.Key.recordRecentFiles.rawValue)
  preferenceWrite.signal()
}
check(preferenceWrite.wait(timeout: .now() + 2) == .success,
      "The real defaults KVO notification completes from a worker queue")
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
check(controller.recentDocuments.isEmpty && controller.resumeButton.isHidden,
      "Disabling recent history immediately removes old files without an explicit reload")
let empty = walk(content).first { $0.identifier?.rawValue == "welcome.empty" }!
check(!empty.isHidden, "No-history mode displays the native empty state")
window.setContentSize(NSSize(width: 860, height: 600))
content.layoutSubtreeIfNeeded()
check(controller.primaryOpenButton.bounds.width >= 300, "The primary action remains usable at the minimum width")
check(!controller.primaryOpenButton.hasAmbiguousLayout, "The primary action has unambiguous layout")
check(!controller.recentFilesTableView.enclosingScrollView!.hasAmbiguousLayout,
      "The recent file list has unambiguous layout")
let openFrame = controller.primaryOpenButton.convert(controller.primaryOpenButton.bounds, to: content)
check(content.bounds.contains(openFrame), "The open action remains inside the minimum-size window")
let featureLabels = walk(content).compactMap { $0 as? NSTextField }
let privacy = featureLabels.first { $0.stringValue.contains("NO MEDIA UPLOADS") || $0.stringValue.contains("你的影像不会上传") }!
let subtitleFeature = featureLabels.first { $0.stringValue == "AI subtitles" || $0.stringValue == "AI 字幕" }!
let privacyFrame = privacy.convert(privacy.bounds, to: content)
let subtitleFeatureFrame = subtitleFeature.convert(subtitleFeature.bounds, to: content)
check(privacyFrame.maxY < subtitleFeatureFrame.minY, "Feature labels do not overlap the footer at minimum size")
print("Welcome design checks passed: \(checks)")
