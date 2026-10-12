import Foundation

// Keep the Core routing guards and delivery real while the legacy fixture
// supplies only application services and traps any native handoff attempt.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let source = try String(contentsOf: root.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)
func method(_ signature: String) -> String {
  guard source.components(separatedBy: signature).count == 2,
        let begin = source.range(of: signature)?.lowerBound,
        let end = source.range(of: "\n  }", range: begin..<source.endIndex)?.upperBound else {
    fatalError("Production rotation extraction boundary changed: \(signature)")
  }
  return String(source[begin..<end])
}
let generated = """
import AppKit
extension PlayerCore {
  @discardableResult
\(method("  func requestPermanentRotation("))
\(method("  private func deliverPermanentRotation("))
  @discardableResult
\(method("  func cancelPendingPermanentRotation("))
}
"""
try generated.write(to: output, atomically: true, encoding: .utf8)
