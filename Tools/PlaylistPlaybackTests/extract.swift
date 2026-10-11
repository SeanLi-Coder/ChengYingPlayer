import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let source = try String(contentsOf: root.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)

func section(_ start: String, _ end: String) -> String {
  guard let begin = source.range(of: start)?.lowerBound,
        let finish = source.range(of: end, range: begin..<source.endIndex)?.lowerBound else {
    fatalError("Production queue extraction boundaries changed")
  }
  return String(source[begin..<finish])
}

let append = section("  func appendToPlaylist(", "  func playlistMove(")
let insert = section("  func addToPlaylist(", "  func playlistRemove(")
for method in [append, insert] {
  guard let lock = method.range(of: "playlistMutationLock.lock()"),
        let admission = method.range(of: "isOpeningMediaBlocked"),
        let mutation = method.range(of: "mpv.playlistAppend"),
        lock.upperBound < admission.lowerBound, admission.upperBound < mutation.lowerBound else {
    fatalError("Queue admission must be checked inside the mutation lock before appending")
  }
}

let generated = """
import Foundation

final class PlaylistAdmissionPlayer: PlaylistAdmissionBoundary {
\(append)
\(insert)
}
"""
try generated.write(to: output.appendingPathComponent("PlayerAdmission.swift"), atomically: true, encoding: .utf8)
