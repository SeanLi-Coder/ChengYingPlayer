import Foundation

// Compile the current production bodies unchanged against controllable boundaries.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let player = try String(contentsOf: root.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)
let controller = try String(contentsOf: root.appendingPathComponent("iina/MPVController.swift"), encoding: .utf8)

func section(_ source: String, _ start: String, _ end: String) -> String {
  guard let begin = source.range(of: start)?.lowerBound,
        let finish = source.range(of: end, range: begin..<source.endIndex)?.lowerBound else {
    fatalError("Production extraction boundaries changed: \(start) ... \(end)")
  }
  return String(source[begin..<finish])
}

let declarations = section(player, "  @Atomic var backgroundQueueTicket", "  var initialWindow:")
let start = section(player, "  func fileStarted(path:", "  /// A [MPV_EVENT_FILE_LOADED]")
let stop = section(player, "  func stop() {", "  func toggleMute(")
let shutdown = section(player, "  func shutdown() {", "  /// Respond to the mpv core shutting down.")
let playerSource = """
import Foundation

final class PlayerUnderTest: PlayerFixture {
\(declarations)
\(start)
\(stop)
\(shutdown)
  func checkTicket(_ ticket: Int) throws {
    if backgroundQueueTicket != ticket { throw TicketExpiredError.ticketExpired }
  }
}
"""
// Only access control is relaxed in the temporary test copy.
try playerSource.replacingOccurrences(of: "private ", with: "")
  .write(to: output.appendingPathComponent("Player.swift"), atomically: true, encoding: .utf8)

let filters = section(controller, "  func getFilters(_ name:", "  /** Set filter. only")
let controllerSource = """
import Foundation

final class FilterControllerUnderTest {
  var mpv: FilterMPV? = FilterMPV()
  func log(_ message: String, level: Logger.Level = .debug) {}
\(filters)
}
"""
try controllerSource.write(to: output.appendingPathComponent("Controller.swift"), atomically: true, encoding: .utf8)
let liveControllerSource = """
import Foundation

final class FilterControllerUnderTest {
  var mpv: OpaquePointer?
  init(_ handle: OpaquePointer?) { mpv = handle }
  func log(_ message: String, level: Logger.Level = .debug) {}
\(filters)
}
"""
try liveControllerSource.write(to: output.appendingPathComponent("LiveController.swift"), atomically: true, encoding: .utf8)
