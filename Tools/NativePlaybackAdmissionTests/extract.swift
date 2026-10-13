import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let source = try String(contentsOf: root.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)
let signature = "  private func attemptNativeOpen(_ url: URL) -> Bool {"
guard source.components(separatedBy: signature).count == 2,
      let start = source.range(of: signature)?.lowerBound,
      let end = source.range(of: "\n  }", range: start..<source.endIndex)?.upperBound else {
  fatalError("Native admission extraction boundary changed")
}
var method = String(source[start..<end])
if ProcessInfo.processInfo.environment["NATIVE_ADMISSION_NEGATIVE_CONTROL"] == "1" {
  let current = "let loadSiblings = info.shouldAutoLoadFiles && Preference.bool(for: .playlistAutoAdd)"
  precondition(method.components(separatedBy: current).count == 2, "Admission negative-control landmark changed")
  method = method.replacingOccurrences(of: current, with: "let loadSiblings = info.shouldAutoLoadFiles")
}
let boundary = try String(contentsOf: root.appendingPathComponent("Tools/NativePlaybackAdmissionTests/Boundary.swift"), encoding: .utf8)
let generated = "import Foundation\n" + boundary + "\nfinal class PlayerCore: AdmissionBoundary {\n" + method + "\n  func testOpen(_ url: URL) -> Bool { attemptNativeOpen(url) }\n}\n"
try generated.write(to: output, atomically: true, encoding: .utf8)
