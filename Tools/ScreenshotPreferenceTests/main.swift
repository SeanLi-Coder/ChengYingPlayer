import Foundation
import ImageIO

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

func checkedSuite(_ name: String) -> UserDefaults {
  let prefix = "org.chengying.tests.ScreenshotPreference."
  guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
        let defaults = UserDefaults(suiteName: name) else {
    fatalError("Only an isolated UUID preference suite is allowed")
  }
  return defaults
}

let key = Preference.Key.screenshotFormat.rawValue
let frameKey = Preference.Key.frameExtractionFormat.rawValue
if CommandLine.arguments.count == 6 && CommandLine.arguments[2] == "--read-suite" {
  let suite = checkedSuite(CommandLine.arguments[3])
  Preference.testDefaults = suite
  suite.register(defaults: Preference.registeredDefaults)
  let expected = Int(CommandLine.arguments[4])!
  let stored = suite.persistentDomain(forName: CommandLine.arguments[3])?[key] as? Int
  let expectedStored = Int(CommandLine.arguments[5])
  check(Preference.ScreenshotFormat(key: .screenshotFormat)?.rawValue == expected && stored == expectedStored,
        "Fresh process preserves the screenshot format")
  exit(0)
}

guard CommandLine.arguments.count == 3 else {
  fatalError("Usage: ScreenshotPreferenceTests SOURCE_ROOT FIXTURE_ROOT")
}
let sourceRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let suiteName = "org.chengying.tests.ScreenshotPreference.\(UUID().uuidString)"
let defaults = checkedSuite(suiteName)
Preference.testDefaults = defaults
cleanupOnFailure = {
  defaults.removePersistentDomain(forName: suiteName)
  defaults.synchronize()
}
defer { cleanupOnFailure?() }

func verifyRestart(expected: Int, stored: Int?) {
  check(defaults.synchronize(), "Flush only the isolated test preference suite")
  let process = Process()
  process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  process.arguments = [sourceRoot.path, "--read-suite", suiteName, String(expected), stored.map(String.init) ?? "none"]
  let output = Pipe()
  process.standardOutput = output
  process.standardError = output
  try! process.run()
  let deadline = Date().addingTimeInterval(10)
  while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
  if process.isRunning { process.terminate() }
  check(!process.isRunning, "The isolated preference restart check completes")
  process.waitUntilExit()
  check(process.terminationStatus == 0, "The screenshot choice survives a fresh process")
}

check(key == "screenShotFormat", "Preserve the existing persistent screenshot key")
check(Preference.ScreenshotFormat.defaultValue == .jpg, "The production enum fallback is JPEG with a jpg extension")
check(productionJPEGQuality == 100, "The production JPEG encoder uses maximum quality")
let expectedFormats = ["png", "jpg", "jpeg", "webp", "jxl"]
for (rawValue, name) in expectedFormats.enumerated() {
  check(Preference.ScreenshotFormat(rawValue: rawValue)?.string == name,
        "Preserve screenshot format raw value \(rawValue) for \(name)")
}
check(Preference.ScreenshotFormat(rawValue: -1) == nil && Preference.ScreenshotFormat(rawValue: 5) == nil,
      "Unrecognized raw values remain invalid")
defaults.register(defaults: Preference.registeredDefaults)
check(Preference.ScreenshotFormat(key: .screenshotFormat) == .jpg,
      "An unset screenshot preference resolves to jpg")
check(defaults.persistentDomain(forName: suiteName)?[key] == nil,
      "The registered jpg default does not overwrite a persistent preference")
check(defaults.string(forKey: frameKey) == "jpg", "Frame extraction also registers a jpg default")
verifyRestart(expected: 1, stored: nil)
defaults.register(defaults: [key: 0])
check(Preference.ScreenshotFormat(key: .screenshotFormat) == .png, "Model the previous implicit PNG default")
defaults.register(defaults: Preference.registeredDefaults)
check(Preference.ScreenshotFormat(key: .screenshotFormat) == .jpg, "An old implicit PNG default updates to jpg")
verifyRestart(expected: 1, stored: nil)
for (rawValue, name) in expectedFormats.enumerated() {
  defaults.set(rawValue, forKey: key)
  defaults.register(defaults: Preference.registeredDefaults)
  check(Preference.ScreenshotFormat(key: .screenshotFormat)?.string == name,
        "An explicitly saved \(name) choice is preserved")
  verifyRestart(expected: rawValue, stored: rawValue)
}
defaults.set("png", forKey: frameKey)
defaults.register(defaults: Preference.registeredDefaults)
check(defaults.string(forKey: frameKey) == "png", "Preserve an explicitly saved frame-extraction format")
defaults.removeObject(forKey: key)
check(Preference.ScreenshotFormat(key: .screenshotFormat) == .jpg, "Clearing a saved format restores the jpg default")

func compactSource(_ name: String) throws -> String {
  try String(contentsOf: sourceRoot.appendingPathComponent("iina/\(name).swift"), encoding: .utf8)
    .components(separatedBy: .whitespacesAndNewlines).joined()
}
let appDelegate = try compactSource("AppDelegate")
check(appDelegate.contains("UserDefaults.standard.register(defaults:") &&
      appDelegate.contains("Preference.defaultPreference.map"),
      "App startup registers defaults instead of persisting a forced migration")
let controller = try compactSource("MPVController")
check(controller.contains("setUserOption(PK.screenshotFormat,type:.other,forName:MPVOption.Screenshot.screenshotFormat,") &&
      controller.contains("letformat=Preference.ScreenshotFormat(rawValue:v)") && controller.contains("returnformat?.string"),
      "The existing live mpv binding reads the stored enum value")
let core = try compactSource("PlayerCore")
check(core.contains("commandFlags.append(includeSubtitles?\"subtitles\":\"video\")"),
      "Default screenshots capture the video frame rather than the resized window")
let xib = try XMLDocument(contentsOf: sourceRoot.appendingPathComponent("iina/Base.lproj/PrefGeneralViewController.xib"),
                          options: [.nodeLoadExternalEntitiesNever])
let controls = try xib.nodes(forXPath: "//popUpButton[connections/binding[@name='selectedTag' and @keyPath='values.screenShotFormat']]")
check(controls.count == 1, "The format selector remains bound to the existing persistent key")
let choices = try controls[0].nodes(forXPath: "popUpButtonCell/menu/items/menuItem")
for (index, title) in ["PNG", "JPEG (.jpg)", "JPEG (.jpeg)", "WebP (.webp)", "JPEG XL (.jxl)"].enumerated() {
  check(choices.contains { node in
    guard let item = node as? XMLElement else { return false }
    return item.attribute(forName: "title")?.stringValue == title &&
      (Int(item.attribute(forName: "tag")?.stringValue ?? "0") == index)
  }, "The UI preserves the saved enum tag for \(title)")
}

func command(_ handle: OpaquePointer, _ arguments: [String]) {
  let strings = arguments.map { strdup($0)! }
  defer { strings.forEach { free($0) } }
  var pointers: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) }
  pointers.append(nil)
  check(mpv_command(handle, &pointers) >= 0, "Run actual mpv command: \(arguments[0])")
}

for (width, height) in [(640, 360), (360, 640)] {
  guard let handle = mpv_create() else { fatalError("Cannot create the real libmpv core") }
  defer { mpv_terminate_destroy(handle) }
  for (name, value) in ["config": "no", "terminal": "no", "input-terminal": "no", "vo": "null",
                        "ao": "null", "hwdec": "no", "pause": "yes", "idle": "yes", "keep-open": "yes",
                        "resume-playback": "no", "save-position-on-quit": "no", "screenshot-template": "frame-%n",
                        "screenshot-dir": directory.path, "screenshot-jpeg-quality": String(productionJPEGQuality),
                        "screenshot-format": Preference.ScreenshotFormat(key: .screenshotFormat)!.string] {
    check(mpv_set_option_string(handle, name, value) >= 0, "Configure the isolated real libmpv: \(name)")
  }
  check(mpv_initialize(handle) >= 0, "Initialize real libmpv")
  var actualQuality: Int64 = 0
  check(mpv_get_property(handle, "options/screenshot-jpeg-quality", MPV_FORMAT_INT64, &actualQuality) >= 0 &&
        actualQuality == 100, "The actual encoder receives JPEG quality 100")
  command(handle, ["loadfile", directory.appendingPathComponent("\(width)x\(height).mp4").path])
  var ready = false
  let deadline = Date().addingTimeInterval(15)
  while !ready && Date() < deadline {
    let event = mpv_wait_event(handle, 0.1).pointee
    ready = event.event_id == MPV_EVENT_PLAYBACK_RESTART
    if event.event_id == MPV_EVENT_SHUTDOWN || event.event_id == MPV_EVENT_END_FILE {
      check(false, "The generated video stays available for a screenshot")
    }
  }
  check(ready, "The real decoder prepares a video frame")
  // The default video/subtitles modes must retain source dimensions even when zoomed.
  check(mpv_set_property_string(handle, "video-zoom", "1") >= 0, "Apply a non-default display zoom")
  for (format, flag) in [("jpg", "video"), ("jpg", "subtitles"), ("png", "video"), ("jpeg", "video")] {
    let before = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    check(mpv_set_property_string(handle, "screenshot-format", format) >= 0, "Select the actual \(format) encoder")
    command(handle, ["screenshot", flag])
    let after = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    let created = after.subtracting(before)
    check(created.count == 1, "The screenshot command creates exactly one image")
    let filename = created.first!
    // mpv treats jpeg as an alias of jpg and uses the canonical jpg extension.
    let expectedExtension = format == "png" ? "png" : "jpg"
    check(filename.hasSuffix(".\(expectedExtension)"),
          "The real \(format) encoder produces the canonical .\(expectedExtension) extension")
    let url = directory.appendingPathComponent(filename)
    let bytes = try Data(contentsOf: url)
    check(format == "png" ? bytes.starts(with: [137, 80, 78, 71]) : bytes.starts(with: [255, 216, 255]),
          "The encoded image magic matches its extension")
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
      check(false, "ImageIO can decode the actual screenshot")
      fatalError("Unreachable")
    }
    check(image.width == width && image.height == height,
          "The \(format) screenshot preserves the original \(width)x\(height) dimensions despite display zoom")
    check(CGImageSourceGetType(imageSource) as String? == (format == "png" ? "public.png" : "public.jpeg"),
          "ImageIO identifies the encoded image format independently of its filename")
  }
}
print("Screenshot preference and real encoding checks passed: \(checks)")
print("Coverage: production enum/default wiring, isolated preferences, software-decoded screenshots; no user media or preferences were accessed.")
