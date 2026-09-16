import Foundation

setbuf(stdout, nil)
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
  guard value() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}

guard CommandLine.arguments.count == 3 else {
  fatalError("Usage: SimplificationTests <project-root> <cli-path>")
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

// Exercise the production policy, including old commands that remain parseable for compatibility.
let retiredCommands = [
  "open-url", "find-online-subs", "save-downloaded-sub", "toggle-music-mode",
  "delete-current-file-hard"
]
let supportedCommands = [
  "toggle-pip", "open-file", "audio-panel", "video-panel", "sub-panel",
  "playlist-panel", "chapter-panel", "toggle-flip", "toggle-mirror", "bigger-window",
  "smaller-window", "fit-to-screen", "save-playlist", "show-current-file-in-finder",
  "delete-current-file"
]
for name in retiredCommands {
  guard let command = IINACommand(rawValue: name) else {
    fatalError("Legacy command must remain parseable: \(name)")
  }
  check(!command.isAvailable, "Retired native command is unavailable: \(name)")
}
for name in supportedCommands {
  check(IINACommand(rawValue: name)?.isAvailable == true, "Core native command remains available: \(name)")
}
check(IINACommand(rawValue: "unknown-native-command") == nil, "Unknown native commands remain invalid")

struct PreferenceXIB {
  let name: String
  let document: XMLDocument
  let source: String
  let identifiers: Set<String>

  init(_ name: String) throws {
    self.name = name
    document = try XMLDocument(contentsOf: root.appendingPathComponent("iina/Base.lproj/\(name).xib"))
    source = try String(contentsOf: root.appendingPathComponent("iina/\(name).swift"), encoding: .utf8)
    let identifierValues = try document.nodes(forXPath: "//*[@id]/@id").compactMap(\.stringValue)
    identifiers = Set(identifierValues)
    check(identifiers.count == identifierValues.count, "\(name) has unique Interface Builder identifiers")

    // Deleted controls must not leave dangling constraints, outlets, bindings, or selected items.
    for attribute in ["destination", "target", "firstItem", "secondItem", "selectedItem"] {
      let references = try document.nodes(forXPath: "//@\(attribute)").compactMap(\.stringValue)
      let missing = Set(references).subtracting(identifiers)
      check(missing.isEmpty, "\(name) has no dangling \(attribute) references: \(missing.sorted())")
    }

    let properties = try document.nodes(forXPath: "//*[@id='-2']/connections/outlet/@property")
      .compactMap(\.stringValue).filter { $0 != "view" }
    let missingProperties = properties.filter {
      source.range(of: "@IBOutlet\\s+(?:weak\\s+)?var\\s+\($0)\\s*:", options: .regularExpression) == nil
    }
    check(missingProperties.isEmpty, "\(name) owner outlets match real Swift properties: \(missingProperties)")

    let actions = try document.nodes(forXPath: "//action[@target='-2']/@selector").compactMap(\.stringValue)
    let missingActions = actions.filter { selector in
      let method = selector.components(separatedBy: ":")[0]
      return source.range(of: "func\\s+\(method)\\s*\\(", options: .regularExpression) == nil
    }
    check(missingActions.isEmpty, "\(name) actions match real Swift methods: \(missingActions)")
  }

  func values(_ xpath: String) throws -> Set<String> {
    Set(try document.nodes(forXPath: xpath).compactMap(\.stringValue))
  }

  func requireBindings(_ keys: [String]) throws {
    let bindings = try values("//binding/@keyPath")
    for key in keys {
      check(bindings.contains("values.\(key)"), "\(name) preserves the \(key) control")
    }
  }

  func forbidBindings(_ keys: [String]) throws {
    let bindings = try values("//binding/@keyPath")
    for key in keys {
      check(!bindings.contains("values.\(key)"), "\(name) removes the \(key) control rather than hiding it")
    }
  }

  func requireOutlets(_ properties: [String]) throws {
    let outlets = try values("//*[@id='-2']/connections/outlet/@property")
    for property in properties {
      check(outlets.contains(property), "\(name) preserves the \(property) outlet")
    }
  }

  func forbidOutlets(_ properties: [String]) throws {
    let outlets = try values("//*[@id='-2']/connections/outlet/@property")
    for property in properties {
      check(!outlets.contains(property), "\(name) removes the \(property) outlet")
    }
  }
}

let general = try PreferenceXIB("PrefGeneralViewController")
try general.forbidBindings([
  "autoSwitchToMusicMode", "playlistShowMetadataInMusicMode", "receiveBetaUpdate"
])
let generalBindings = try general.values("//binding/@keyPath")
check(!generalBindings.contains(where: { $0.contains("updaterController") }), "General preferences remove the nonfunctional updater bindings")
try general.requireBindings([
  "resumeLastPosition", "pauseWhenOpen", "preventScreenSaver", "playlistAutoPlayNext",
  "screenShotFormat", "screenShotIncludeSubtitle", "screenshotSaveToFile", "recordPlaybackHistory"
])
try general.requireOutlets(["behaviorView", "historyView", "playlistView", "screenshotsView"])

let codec = try PreferenceXIB("PrefCodecViewController")
try codec.forbidBindings([
  "videoThreads", "audioThreads", "forceDedicatedGPU", "audioDriverEnableAVFoundation",
  "gaplessAudio", "spdifAC3", "spdifDTS", "spdifDTSHD", "replayGain", "replayGainPreamp",
  "replayGainClip", "replayGainFallback"
])
try codec.requireBindings([
  "hardwareDecoder", "loadIccProfile", "enableHdrSupport", "enableToneMapping",
  "toneMappingAlgorithm", "initialVolume", "maxVolume"
])
try codec.requireOutlets([
  "sectionVideoView", "sectionAudioView", "audioDevicePopUp", "audioLangTokenField",
  "hwdecDescriptionTextField", "enableToneMappingBtn", "toneMappingTargetPeakTextField",
  "toneMappingAlgorithmPopUpBtn"
])
try codec.forbidOutlets([
  "sectionReplayGainView", "audioDriverExperimentalIndicator", "spdifAC3Btn", "spdifDTSBtn",
  "spdifDTSHDBtn", "gaplessAudioDescriptionTextField"
])

let utilities = try PreferenceXIB("PrefUtilsViewController")
try utilities.requireOutlets(["sectionDefaultAppView", "sectionClearCacheView"])
try utilities.forbidOutlets(["sectionRestoreAlertsView"])
let utilityActions = try utilities.values("//action/@selector")
check(utilityActions.contains("setIINAAsDefaultAction:"), "Setting the default local player remains available")
check(utilityActions.contains("clearHistoryBtnAction:"), "Clearing playback history remains available")
check(!utilityActions.contains("resetSuppressedAlertsBtnAction:"), "The no-op restore-alerts action is absent from the utility interface")

// Inspect every shipped binding preset, not a copied test fixture.
let configDirectory = root.appendingPathComponent("iina/config", isDirectory: true)
let presets = try FileManager.default.contentsOfDirectory(at: configDirectory, includingPropertiesForKeys: nil)
  .filter { $0.pathExtension == "conf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
check(presets.count >= 5, "All shipped input presets are included in the regression check")
for preset in presets {
  let contents = try String(contentsOf: preset, encoding: .utf8)
  let commands = contents.split(separator: "\n").compactMap { line -> String? in
    let tokens = line.split(whereSeparator: \.isWhitespace)
    guard tokens.count >= 3, tokens[0] == "#@iina" else { return nil }
    return String(tokens[2])
  }
  let unavailable = commands.filter { IINACommand(rawValue: $0)?.isAvailable == false }
  check(unavailable.isEmpty, "\(preset.lastPathComponent) does not restore retired commands: \(unavailable)")
}

let menuDocument = try XMLDocument(contentsOf: root.appendingPathComponent("iina/Base.lproj/MainMenu.xib"))
func menuObject(for outlet: String) throws -> XMLElement {
  guard let target = try menuDocument.nodes(forXPath: "//outlet[@property='\(outlet)']/@destination").first?.stringValue,
        let element = try menuDocument.nodes(forXPath: "//*[@id='\(target)']").first as? XMLElement else {
    fatalError("Missing main-menu outlet: \(outlet)")
  }
  return element
}
func isHiddenInMenu(_ node: XMLNode) -> Bool {
  var current: XMLNode? = node
  while let element = current {
    if (element as? XMLElement)?.attribute(forName: "hidden")?.stringValue == "YES" {
      return true
    }
    current = element.parent
  }
  return false
}
func descendantElements(_ element: XMLElement) -> [XMLElement] {
  [element] + (element.children ?? []).compactMap { $0 as? XMLElement }.flatMap(descendantElements)
}
for outlet in ["miniPlayer", "delogo", "videoFilters", "audioFilters", "savedVideoFiltersMenu", "savedAudioFiltersMenu"] {
  let object = try menuObject(for: outlet)
  check(isHiddenInMenu(object), "The retired \(outlet) entry is hidden in the production menu")
  let shortcuts = descendantElements(object).compactMap { $0.attribute(forName: "keyEquivalent")?.stringValue }
  check(shortcuts.allSatisfy(\.isEmpty), "The retired \(outlet) entry has no Interface Builder keyboard shortcuts")
}
for outlet in [
  "pictureInPicture", "abLoop", "screenshot", "quickSettingsVideo", "quickSettingsAudio",
  "quickSettingsSub", "cropMenu", "rotationMenu", "speedUp", "speedDown", "speedReset",
  "audioTrackMenu", "subTrackMenu", "chapterMenu", "deleteCurrentFile"
] {
  let object = try menuObject(for: outlet)
  check(!isHiddenInMenu(object), "The core \(outlet) entry remains visible in the production menu")
}

// Execute the real launcher parser. The sibling fixture is never launched by these cases.
func runCLI(_ arguments: [String]) throws -> (status: Int32, output: String) {
  let process = Process()
  let output = Pipe()
  process.executableURL = URL(fileURLWithPath: CommandLine.arguments[2])
  process.arguments = arguments
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = output
  process.standardError = output
  try process.run()
  let bytes = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
}
let help = try runCLI(["--help"])
check(help.status == 0, "The production CLI still provides help")
check(!help.output.contains("--music-mode"), "The production CLI does not advertise music mode")
check(help.output.contains("--pip") && help.output.contains("--separate-windows"), "The production CLI retains PiP and local multi-window options")
for argument in ["--music-mode", "--music-mode=yes", "--music-mode=no"] {
  let response = try runCLI([argument, "--no-stdin"])
  check(response.status == 64 && response.output.contains("no longer supported"), "The production CLI rejects retired option \(argument) with a usage error")
}

// Source integration guards complement, but do not replace, the runtime and XIB checks above.
let playlistSource = try String(contentsOf: root.appendingPathComponent("iina/PlaylistViewController.swift"), encoding: .utf8)
let miniPlayerSource = try String(contentsOf: root.appendingPathComponent("iina/MiniPlayerWindowController.swift"), encoding: .utf8)
check(!miniPlayerSource.contains("overrideAutoSwitchToMusicMode"),
      "Source integration: the legacy window lifecycle does not reference removed music state")
check(!playlistSource.contains(".playlistShowMetadataInMusicMode"), "Source integration: playlist display ignores the retired music-only preference")
check(playlistSource.contains(".playlistShowMetadata"), "Source integration: the general playlist metadata preference is preserved")
check(playlistSource.contains("Utility.mediaType(forExtension: fileExtension) == .audio"),
      "Source integration: video filenames are not replaced by shared embedded music titles")
let toolbarSource = try String(contentsOf: root.appendingPathComponent("iina/PrefOSCToolbarSettingsSheetController.swift"), encoding: .utf8)
check(toolbarSource.range(of: "for\\s+\\w+\\s+in\\s+allButtonTypes\\s+where\\s+\\w+\\.isAvailable", options: .regularExpression) != nil,
      "Source integration: the toolbar customization palette filters unavailable buttons")

print("All \(checks) simplification policy and production XIB checks passed.")
