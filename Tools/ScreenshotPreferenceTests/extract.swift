import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let source = try String(contentsOf: root.appendingPathComponent("iina/Preference.swift"), encoding: .utf8)
let controller = try String(contentsOf: root.appendingPathComponent("iina/MPVController.swift"), encoding: .utf8)

func capture(_ pattern: String, in source: String) -> String {
  let expression = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
  let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
  guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: source) else {
    fatalError("Expected exactly one production match: \(pattern)")
  }
  return String(source[range])
}

guard let start = source.range(of: "  enum ScreenshotFormat:")?.lowerBound,
      let end = source.range(of: "  enum HardwareDecoderOption:", range: start..<source.endIndex)?.lowerBound else {
  fatalError("Production screenshot enum extraction boundaries changed")
}
let screenshotEnum = String(source[start..<end])
let screenshotKey = capture(#"^\s*static let screenshotFormat = Key\("([^"]+)"\)"#, in: source)
let frameKey = capture(#"^\s*static let frameExtractionFormat = Key\("([^"]+)"\)"#, in: source)
let formatDefault = capture(#"^\s*\.screenshotFormat:\s*(ScreenshotFormat\.\w+\.rawValue),"#, in: source)
let frameDefault = capture(#"^\s*\.frameExtractionFormat:\s*("[^"]+"),"#, in: source)
let quality = capture(#"setOptionInt\(MPVOption\.Screenshot\.screenshotJpegQuality,\s*(\d+),"#, in: controller)

// Compile the production enum unchanged; substitute only its preference store.
let fixture = """
import Foundation

protocol InitializingFromKey {
  static var defaultValue: Self { get }
  init?(key: Preference.Key)
}

struct Preference {
  struct Key {
    var rawValue: String
    static let screenshotFormat = Key(rawValue: "\(screenshotKey)")
    static let frameExtractionFormat = Key(rawValue: "\(frameKey)")
  }
  static var testDefaults: UserDefaults!
  static func integer(for key: Key) -> Int { testDefaults.integer(forKey: key.rawValue) }
  \(screenshotEnum)
  static let registeredDefaults: [String: Any] = [
    Key.screenshotFormat.rawValue: \(formatDefault),
    Key.frameExtractionFormat.rawValue: \(frameDefault)
  ]
}
let productionJPEGQuality = \(quality)
"""
try fixture.write(to: output.appendingPathComponent("PreferenceFixture.swift"), atomically: true, encoding: .utf8)
