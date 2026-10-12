import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let source = try String(contentsOf: root.appendingPathComponent("iina/DraggingDetect.swift"), encoding: .utf8)
guard let start = source.range(of: "  func openFromPasteboard(_ sender: NSDraggingInfo) -> Bool {")?.lowerBound,
      let end = source.range(of: "\n  }", range: start..<source.endIndex)?.upperBound else {
  fatalError("Production drop method extraction boundaries changed")
}
var method = String(source[start..<end])
if let negative = ProcessInfo.processInfo.environment["NATIVE_DROP_TEST_SKIP_COMPATIBILITY"] {
  precondition(negative == "1", "Unknown negative control")
  let gate = "if isUsingNativePlayback {"
  precondition(method.components(separatedBy: gate).count == 3, "Compatibility gate landmarks changed")
  method = method.replacingOccurrences(of: gate, with: "if false {")
}
try ("import AppKit\n\nextension PlayerCore {\n" + method + "\n}\n")
  .write(to: output, atomically: true, encoding: .utf8)
