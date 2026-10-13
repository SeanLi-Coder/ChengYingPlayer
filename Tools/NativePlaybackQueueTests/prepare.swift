import Foundation

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let mode = CommandLine.arguments[3]
var text = try String(contentsOf: source, encoding: .utf8)
let replacements: [String: (String, String)] = [
  "stale-checkpoint": ("          checkpoint.revision == revision,\n", ""),
  "same-generation": ("generation = nextGeneration; phase = .loading", "_ = nextGeneration; phase = .loading"),
  "stale-eof": ("    guard token == mediaToken else { return .rejected(.stale) }\n", ""),
  "rewind-generation": ("      revision = next; phase = .loading", "      generation += 1; revision = next; phase = .loading")
]
if mode != "positive" {
  guard let replacement = replacements[mode], text.components(separatedBy: replacement.0).count == 2 else {
    fatalError("Queue negative-control landmark changed")
  }
  text = text.replacingOccurrences(of: replacement.0, with: replacement.1)
}
try text.write(to: destination, atomically: true, encoding: .utf8)
