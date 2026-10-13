import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let source = try String(contentsOf: root.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)
guard let start = source.range(of: "  private func retireNativePlayback(")?.lowerBound,
      let end = source.range(of: "\n  private func open(", range: start..<source.endIndex)?.lowerBound else {
  fatalError("Production retirement extraction landmarks changed")
}
var method = String(source[start..<end])
let negative = ProcessInfo.processInfo.environment["NATIVE_VIEW_NEGATIVE_CONTROL"] ?? ""
if negative == "skip-retirement-detach" {
  let call = "      mainWindow.videoView.detachNativePlaybackOutput(transport.session.output)\n"
  precondition(method.components(separatedBy: call).count == 2, "Retirement negative landmark changed")
  method = method.replacingOccurrences(of: call, with: "")
}
let extracted = """
// Mechanically extracted production retirement; no lifecycle policy copy.
extension PlayerCore {
\(method)
  func testRetire(completion: @escaping () -> Void) {
    retireNativePlayback(completion: completion)
  }
}
"""
try extracted.write(to: directory.appendingPathComponent("Retirement.swift"), atomically: true, encoding: .utf8)
var view = try String(contentsOf: root.appendingPathComponent("iina/VideoView.swift"), encoding: .utf8)
if negative == "ignore-output-owner" {
  let identity = "surface.displayLayer === output.displayLayer"
  precondition(view.components(separatedBy: identity).count == 2, "Owner negative landmark changed")
  view = view.replacingOccurrences(of: identity, with: "true")
}
try view.write(to: directory.appendingPathComponent("VideoView.swift"), atomically: true, encoding: .utf8)
