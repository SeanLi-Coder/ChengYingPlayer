import Foundation

setbuf(stdout, nil)

var checks = 0
var cleanupOnFailure: (() -> Void)?
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    cleanupOnFailure?()
    exit(1)
  }
  checks += 1
  print("PASS: \(message)")
}

func captures(_ expression: String, in source: String) throws -> [String] {
  let pattern = try NSRegularExpression(pattern: expression, options: [.anchorsMatchLines])
  return pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).map { match in
    String(source[Range(match.range(at: 1), in: source)!])
  }
}

func source(_ name: String, root: URL) throws -> String {
  try String(contentsOf: root.appendingPathComponent("iina/\(name).swift"), encoding: .utf8)
}

func compact(_ source: String) -> String {
  source.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined()
}

func checkedSuite(_ name: String) -> UserDefaults {
  let prefix = "org.chengying.tests.HDRPreference."
  guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
        let defaults = UserDefaults(suiteName: name) else {
    fputs("FAIL: Only an isolated UUID test preference suite is permitted\n", stderr)
    exit(1)
  }
  return defaults
}

guard CommandLine.arguments.count >= 2 else {
  fputs("Usage: HDRPreferenceTests /absolute/project/root\n", stderr)
  exit(2)
}
let sourceRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let preferenceSource = try source("Preference", root: sourceRoot)
let keyValues = try captures(#"^\s*static let enableHdrSupport\s*=\s*Key\("([^"]+)"\)"#, in: preferenceSource)
let defaultValues = try captures(#"^\s*\.enableHdrSupport\s*:\s*(true|false)\s*,"#, in: preferenceSource)
guard keyValues.count == 1, defaultValues.count == 1 else {
  fputs("FAIL: Cannot uniquely read the production HDR key and default\n", stderr)
  exit(1)
}
let key = keyValues[0]
let productionDefault = defaultValues[0] == "true"

// Child-process checks prove persisted choices survive a fresh Foundation
// preferences reader; they never open the real application's preference domain.
if CommandLine.arguments.count == 6 && CommandLine.arguments[2] == "--read-suite" {
  let suiteName = CommandLine.arguments[3]
  let defaults = checkedSuite(suiteName)
  defaults.register(defaults: [key: productionDefault])
  let expected = CommandLine.arguments[4] == "true"
  let persisted = defaults.persistentDomain(forName: suiteName)?[key] as? Bool
  let expectedPersisted = CommandLine.arguments[5] == "none" ? nil : Optional(CommandLine.arguments[5] == "true")
  guard defaults.bool(forKey: key) == expected, persisted == expectedPersisted else {
    fputs("FAIL: Fresh process did not preserve the isolated preference semantics\n", stderr)
    exit(1)
  }
  print("PASS: Isolated preference state survived a process restart")
  exit(0)
}

check(key == "enableHdrSupport", "Keep the existing persistent HDR preference key")
check(!productionDefault, "The actual registered production HDR default is off")
let playbackSource = try source("PlaybackInfo", root: sourceRoot)
let initialValues = try captures(#"^\s*var hdrEnabled\s*:\s*Bool\s*=\s*(true|false)"#, in: playbackSource)
check(initialValues == ["false"], "PlaybackInfo starts with HDR off before preferences are applied")

let preferenceCompact = compact(preferenceSource)
let appDelegateCompact = compact(try source("AppDelegate", root: sourceRoot))
let playerCoreCompact = compact(try source("PlayerCore", root: sourceRoot))
let quickSettingsCompact = compact(try source("QuickSettingViewController", root: sourceRoot))
let videoViewCompact = compact(try source("VideoView", root: sourceRoot))
check(appDelegateCompact.contains("UserDefaults.standard.register(defaults:") &&
      appDelegateCompact.contains("Preference.defaultPreference.map"),
      "Application startup registers the production defaults without replacing saved preferences")
check(preferenceCompact.contains("staticfuncbool(forkey:Key)->Bool{returnud.bool(forKey:key.rawValue)}"),
      "Preference.bool continues to read the persistent key through UserDefaults")
check(playerCoreCompact.contains("info.hdrEnabled=Preference.bool(for:.enableHdrSupport)openMainWindow("),
      "Opening a media file applies the user's HDR preference before creating its window")
check(quickSettingsCompact.contains("funchdrAction(_sender:NSSwitch){self.player.info.hdrEnabled=sender.state==.onself.player.refreshEdrMode()}"),
      "The existing HDR switch can still manually enable or disable the current player")
check(quickSettingsCompact.contains("hdrSwitch.isEnabled=player.info.hdrAvailable") &&
      quickSettingsCompact.contains("hdrSwitch.state=(player.info.hdrAvailable&&player.info.hdrEnabled)?.on:.off"),
      "Quick settings reflect both HDR availability and the selected player state")
let hdrGuard = videoViewCompact.range(of: "guardplayer.info.hdrEnabledelse{returnnil}")
let edrEnable = videoViewCompact.range(of: "videoLayer.wantsExtendedDynamicRangeContent=true")
check(hdrGuard != nil && edrEnable != nil && hdrGuard!.lowerBound < edrEnable!.lowerBound,
      "The renderer checks the HDR opt-in before enabling extended dynamic range")
check(videoViewCompact.contains("ifedrEnabled!=true{setICCProfile()}"),
      "HDR-disabled playback retains the existing ICC/SDR rendering fallback")

let codecXIB = try XMLDocument(contentsOf: sourceRoot.appendingPathComponent("iina/Base.lproj/PrefCodecViewController.xib"),
                               options: [.nodeLoadExternalEntitiesNever])
let hdrControls = try codecXIB.nodes(forXPath: "//button[connections/binding[@name='value' and @keyPath='values.enableHdrSupport']]")
check(hdrControls.count == 1, "The codec preferences retain one HDR control bound to the existing saved key")
let hdrControl = hdrControls[0] as! XMLElement
let hdrCells = hdrControl.elements(forName: "buttonCell")
check(hdrCells.count == 1 && hdrCells[0].attribute(forName: "type")?.stringValue == "check",
      "The global HDR preference remains a user-operable checkbox")
let hdrCellState = hdrCells[0].attribute(forName: "state")?.stringValue
check(hdrCellState == nil || hdrCellState == "off", "The HDR checkbox does not start visually checked in the XIB")
let hdrBindings = try hdrControl.nodes(forXPath: "connections/binding[@name='value' and @keyPath='values.enableHdrSupport']")
let boundController = (hdrBindings[0] as! XMLElement).attribute(forName: "destination")?.stringValue
let sharedControllers = try codecXIB.nodes(forXPath: "//userDefaultsController[@representsSharedInstance='YES']")
check(sharedControllers.contains { ($0 as? XMLElement)?.attribute(forName: "id")?.stringValue == boundController },
      "The HDR checkbox stays bound to the existing shared defaults controller")

let suiteName = "org.chengying.tests.HDRPreference.\(UUID().uuidString)"
let defaults = checkedSuite(suiteName)
cleanupOnFailure = {
  defaults.removePersistentDomain(forName: suiteName)
  defaults.synchronize()
}
defer { cleanupOnFailure?() }
check(defaults.persistentDomain(forName: suiteName)?[key] == nil,
      "The new UUID suite contains no saved HDR choice")

func storedChoice() -> Bool? {
  defaults.persistentDomain(forName: suiteName)?[key] as? Bool
}

func verifyRestart(expected: Bool, persisted: Bool?, description: String) {
  check(defaults.synchronize(), "Flush only the isolated test preference suite")
  let process = Process()
  process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  process.arguments = [sourceRoot.path, "--read-suite", suiteName,
                       expected ? "true" : "false", persisted.map { $0 ? "true" : "false" } ?? "none"]
  let output = Pipe()
  process.standardOutput = output
  process.standardError = output
  do { try process.run() } catch {
    check(false, "Launch the isolated preference restart probe")
    return
  }
  let deadline = Date().addingTimeInterval(10)
  while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
  if process.isRunning { process.terminate() }
  check(!process.isRunning, "The isolated restart probe finishes within its deadline")
  process.waitUntilExit()
  let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  check(process.terminationStatus == 0 && text.contains("PASS: Isolated preference state survived a process restart"), description)
}

defaults.register(defaults: [key: productionDefault])
check(!defaults.bool(forKey: key), "An unset HDR preference resolves to the new off default")
check(storedChoice() == nil, "Registering the off default does not manufacture an explicit saved choice")
verifyRestart(expected: false, persisted: nil, description: "An untouched installation remains HDR-off after restart")

defaults.register(defaults: [key: true])
check(defaults.bool(forKey: key), "The isolated fixture models the previous implicit HDR-on default")
check(storedChoice() == nil, "The previous implicit default is not a stored user choice")
defaults.register(defaults: [key: productionDefault])
check(!defaults.bool(forKey: key), "Replacing the old registered default changes an implicit choice to HDR-off")
check(storedChoice() == nil, "Updating the default does not persist a forced migration")
verifyRestart(expected: false, persisted: nil, description: "An old implicit default remains off when the updated app restarts")

defaults.set(true, forKey: key)
defaults.register(defaults: [key: productionDefault])
check(defaults.bool(forKey: key), "An explicitly saved HDR-on choice overrides the new off default")
check(storedChoice() == true, "The explicit HDR-on choice is preserved without overwrite")
verifyRestart(expected: true, persisted: true, description: "An explicit HDR-on preference survives a fresh process")

defaults.set(false, forKey: key)
defaults.register(defaults: [key: true])
check(!defaults.bool(forKey: key), "An explicit HDR-off choice also overrides an old registered on default")
defaults.register(defaults: [key: productionDefault])
check(!defaults.bool(forKey: key) && storedChoice() == false, "The explicit HDR-off choice is preserved by the updated default")
verifyRestart(expected: false, persisted: false, description: "An explicit HDR-off preference survives a fresh process")

defaults.removeObject(forKey: key)
check(storedChoice() == nil, "Removing the isolated saved choice actually clears its persistent entry")
check(!defaults.bool(forKey: key), "Removing a saved choice returns to the production HDR-off default")
verifyRestart(expected: false, persisted: nil, description: "Removing a saved choice stays HDR-off after restart")

print("HDR preference checks passed: \(checks)")
print("Coverage: production source wiring and native UserDefaults only; no HDR display or media playback acceptance was performed.")
