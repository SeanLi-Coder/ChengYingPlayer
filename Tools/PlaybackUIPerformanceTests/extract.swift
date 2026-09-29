import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let controller = try String(contentsOf: root.appendingPathComponent("iina/MainWindowController.swift"), encoding: .utf8)
let extensions = try String(contentsOf: root.appendingPathComponent("iina/Extensions.swift"), encoding: .utf8)
let core = try String(contentsOf: root.appendingPathComponent("iina/PlayerCore.swift"), encoding: .utf8)

func section(_ source: String, _ start: String, _ end: String) -> String {
  guard let begin = source.range(of: start)?.lowerBound,
        let finish = source.range(of: end, range: begin..<source.endIndex)?.lowerBound else {
    fatalError("Production extraction boundaries changed: \(start)")
  }
  return String(source[begin..<finish])
}

let fields = section(controller, "  private var lastAdditionalInfoRefresh", "  /** For blacking out other screens.")
let additional = section(controller, "  func updateAdditionalInfo(", "  // MARK: - UI: Side bar")
let previews = section(controller, "  private func resetThumbnailPreviewCache()", "  /** Display time label when mouse over slider */")
let rotation = section(extensions, "  func rotate(_ degree: Int)", "  /// Try to find a SF Symbol.")
let production = (fields + additional + previews).replacingOccurrences(of: "private ", with: "")
let controlled = production
  .replacingOccurrences(of: "CACurrentMediaTime()", with: "TestClock.now")
  .replacingOccurrences(of: "DateFormatter.localizedString", with: "TestClock.localizedString")
  .replacingOccurrences(of: "PowerSource.getList()", with: "TestPowerSource.getList()")
let source = """
import Cocoa
import QuartzCore

final class NativeController: ControllerFixture {
\(production)
}

final class ControlledController: ControllerFixture {
\(controlled)
}

extension NSImage {
\(rotation)
}
"""
try source.write(to: output.appendingPathComponent("Controller.swift"), atomically: true, encoding: .utf8)

precondition(controller.contains("thumbnailPeekView.imageView.image = thumbnailPreviewImage(for: image, rotation: rotation)"),
             "The hover path must use the production preview cache")
precondition(controller.components(separatedBy: "updateAdditionalInfo(force: true)").count == 3,
             "Both fullscreen entry paths must force a fresh status snapshot")
precondition(core.contains("!mainWindow.additionalInfoView.isHidden"),
             "Hidden fullscreen status must not refresh from the playback timer")
precondition(controller.contains("resetThumbnailPreviewCache()\n        thumbnailPeekView.isHidden = true"),
             "An unavailable thumbnail must invalidate the previous preview")
print("PASS: production hover, fullscreen, and visibility integration checks")
