import Cocoa

_ = NSApplication.shared
NSApp.delegate = AppDelegate.shared
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}

func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }

check(Bundle.main.bundleIdentifier == "io.github.SeanLi-Coder.ChengYingPlayer.WelcomeDesignTests",
      "Welcome tests use a dedicated defaults domain, never the production app domain")
let historyKeys: [Preference.Key] = [.recordRecentFiles, .resumeLastPosition,
                                    .iinaLastPlayedFilePath, .iinaLastPlayedFilePosition]
let touchedKeys = historyKeys + [.themeMaterial]
let savedDefaults = touchedKeys.map { ($0.rawValue, UserDefaults.standard.object(forKey: $0.rawValue)) }
defer {
  for (key, previousValue) in savedDefaults {
    if let previousValue { UserDefaults.standard.set(previousValue, forKey: key) }
    else { UserDefaults.standard.removeObject(forKey: key) }
  }
}
let sentinel = "PRIVATE_WELCOME_HISTORY_SENTINEL"
let privateFile = URL(fileURLWithPath: NSTemporaryDirectory())
  .appendingPathComponent(sentinel).appendingPathComponent("private-video.mov")
Preference.values[.iinaLastPlayedFilePath] = privateFile
Preference.values[.iinaLastPlayedFilePosition] = 84.0
UserDefaults.standard.set(true, forKey: Preference.Key.recordRecentFiles.rawValue)
UserDefaults.standard.set(true, forKey: Preference.Key.resumeLastPosition.rawValue)
UserDefaults.standard.set(privateFile.absoluteString, forKey: Preference.Key.iinaLastPlayedFilePath.rawValue)
UserDefaults.standard.set(84.0, forKey: Preference.Key.iinaLastPlayedFilePosition.rawValue)
UserDefaults.standard.set(Preference.Theme.dark.rawValue, forKey: Preference.Key.themeMaterial.rawValue)
func historySnapshot() -> NSDictionary {
  Dictionary(uniqueKeysWithValues: historyKeys.map {
    ($0.rawValue, UserDefaults.standard.object(forKey: $0.rawValue)!)
  }) as NSDictionary
}
let historyBefore = historySnapshot()
let player = PlayerCore()
let controller = WelcomeHarness(playerCore: player)
let icon = NSImage(contentsOf: Bundle.main.url(forResource: "welcome-icon", withExtension: "png")!)!
icon.setName("iina_arrow")
let window = controller.window!
let content = window.contentView!
window.orderFront(nil)
content.layoutSubtreeIfNeeded()
check(controller.loaded, "The real production controller builds a native welcome view")
check(window.title == "ChengYing View" || window.title == "澄影视界", "Welcome keeps the media-viewer brand")
check(controller.primaryOpenButton.keyEquivalent == "o", "Open keeps its Command-O shortcut")
check(controller.primaryOpenButton.keyEquivalentModifierMask == [.command], "Command-O keeps its command modifier")
controller.primaryOpenButton.performClick(nil)
check(AppDelegate.shared.openedFilePanels == 1, "The primary action opens the existing local file panel")
controller.downloadCenterButton.performClick(nil)
check(AppDelegate.shared.openedDownloadCenters == 1, "The download action still routes through the app delegate")
check((content as? InitialWindowContentView)?.player === player, "The drop view retains its existing player routing")

func sendKey(_ code: UInt16) {
  controller.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
      charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!)
}
sendKey(36)
sendKey(76)
check(AppDelegate.shared.openedFilePanels == 3, "Return and keypad Enter open a chooser, never a hidden recent file")
sendKey(125)
sendKey(126)
check(player.opened.isEmpty, "Arrow keys and Enter cannot open a hidden history entry")

func checkNoHistory() {
  let views = walk(content)
  check(!views.contains { $0 is NSTableView }, "No hidden or visible recent-files table exists")
  check(!views.contains { $0.identifier?.rawValue.contains("recent") == true ||
    $0.identifier?.rawValue.contains("resume") == true || $0.identifier?.rawValue == "welcome.empty" },
    "No history, resume, or history-empty-state views remain")
  let text = views.flatMap { view -> [String] in
    var values = [view.toolTip, view.accessibilityLabel(), view.accessibilityHelp()].compactMap { $0 }
    if let label = view as? NSTextField { values.append(label.stringValue) }
    if let button = view as? NSButton { values.append(button.title) }
    if let control = view as? NSControl, let cell = control.cell {
      values += [cell.accessibilityLabel(), cell.accessibilityHelp(), cell.accessibilityValue() as? String].compactMap { $0 }
    }
    return values
  }.joined(separator: "\n")
  check(!text.contains(sentinel) && !text.contains(privateFile.lastPathComponent),
        "Neither UI text, tooltips, nor accessibility expose history paths or names")
  check(!text.contains("最近打开") && !text.contains("Recently opened") && !text.contains("继续上次") &&
        !text.contains("CONTINUE WATCHING"), "Welcome contains no history heading or resume prompt")
  check(Preference.reads.allSatisfy { $0 == .themeMaterial }, "Welcome reads only theme preferences, never history metadata")
  check(!views.compactMap { $0 as? NSButton }.contains { $0.title.contains("URL") },
        "Removing history does not restore network playback controls")
}
checkNoHistory()
controller.showWindow(nil)
checkNoHistory()
check(historySnapshot().isEqual(historyBefore), "Opening or reopening welcome does not delete history or change resume settings")

let preferenceWrite = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
  UserDefaults.standard.set("file:///PRIVATE_WELCOME_HISTORY_SENTINEL/changed.mp4",
                            forKey: Preference.Key.iinaLastPlayedFilePath.rawValue)
  UserDefaults.standard.set(false, forKey: Preference.Key.recordRecentFiles.rawValue)
  preferenceWrite.signal()
}
check(preferenceWrite.wait(timeout: .now() + 2) == .success, "A background history update completes without invoking welcome UI")
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
checkNoHistory()
DispatchQueue.global().async {
  UserDefaults.standard.set(Preference.Theme.light.rawValue, forKey: Preference.Key.themeMaterial.rawValue)
  preferenceWrite.signal()
}
check(preferenceWrite.wait(timeout: .now() + 2) == .success, "A worker-thread theme change completes without blocking")
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
check(window.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .aqua, "Theme notifications still update the native window safely")

func checkLayout() {
  content.layoutSubtreeIfNeeded()
  let views = walk(content)
  for button in [controller.primaryOpenButton, controller.downloadCenterButton] {
    let frame = button.convert(button.bounds, to: content)
    check(content.bounds.contains(frame), "Primary actions fit within the content area")
    check(!button.hasAmbiguousLayout && frame.width >= 300, "Primary actions retain usable, unambiguous widths")
    check(abs(frame.midX - content.bounds.midX) < 1, "Single-column actions are centered without an empty library column")
  }
  let ambiguous = views.filter { $0.hasAmbiguousLayout }
  let ambiguousDescription = ambiguous.map { view in
    "\(type(of: view)) \(view.frame) \((view as? NSTextField)?.stringValue ?? "")"
  }.joined(separator: "; ")
  check(ambiguous.isEmpty, "Every native welcome view has unambiguous layout: \(ambiguousDescription)")
  let labels = views.compactMap { $0 as? NSTextField }
  let privacy = labels.first { $0.stringValue.contains("NO MEDIA UPLOADS") || $0.stringValue.contains("你的影像不会上传") }!
  let subtitle = labels.first { $0.stringValue == "AI subtitles" || $0.stringValue == "AI 字幕" }!
  check(privacy.convert(privacy.bounds, to: content).maxY < subtitle.convert(subtitle.bounds, to: content).minY,
        "Feature labels do not overlap the footer at the minimum height")
}
let initialSize = content.bounds.size
check(initialSize.width < 860 && window.contentMinSize.width < 860,
      "The history-free page no longer reserves the former 860-point library width")
for size in [initialSize, window.contentMinSize, NSSize(width: 1000, height: 780)] {
  window.setContentSize(size)
  checkLayout()
}

if let output = ProcessInfo.processInfo.environment["CHENGYING_CAPTURE_DIR"] {
  let directory = URL(fileURLWithPath: output, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let language = Bundle.main.preferredLocalizations.first ?? "en"
  for (theme, appearanceName) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
    for (label, size) in [("default", initialSize), ("minimum", window.contentMinSize)] {
      window.setContentSize(size)
      window.appearance = NSAppearance(named: appearanceName)
      content.layoutSubtreeIfNeeded()
      window.appearance!.performAsCurrentDrawingAppearance {
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
          fatalError("Could not create the native snapshot")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
          fatalError("Could not encode the native snapshot")
        }
        let path = directory.appendingPathComponent("welcome-\(language)-\(theme)-\(label).png")
        try! png.write(to: path)
        print("SNAPSHOT: \(path.path)")
      }
    }
  }
}
window.orderOut(nil)
print("Welcome design checks passed: \(checks)")
