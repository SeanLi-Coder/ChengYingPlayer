import Cocoa

// Playback and chrome policy are boundaries; the three production control classes are unchanged.
final class MainWindowController: NSWindowController {
  private(set) var begins = 0
  private(set) var ends = 0
  private(set) var depth = 0

  func beginControlInteraction() { begins += 1; depth += 1 }
  func endControlInteraction() { ends += 1; depth = max(0, depth - 1) }
}

final class MiniPlayerWindowController: NSWindowController {}

final class PlaySliderCell: NSSliderCell {
  let knobWidth: CGFloat = 3
  let knobHeight: CGFloat = 15
  let knobRadius: CGFloat = 1
  override func barRect(flipped: Bool) -> NSRect { NSRect(x: 0, y: 5, width: 200, height: 3) }
  override func knobRect(flipped: Bool) -> NSRect { NSRect(x: 0, y: 0, width: 3, height: 15) }
}

enum Preference {
  enum Key { case disablePlaySliderScrolling, disableVolumeSliderScrolling }
  static func bool(for key: Key) -> Bool { false }
}

extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

extension NSColor.Name {
  static let mainSliderLoopKnob = NSColor.Name("FixtureLoopKnob")
}

extension Notification.Name {
  static let iinaPlaySliderLoopKnobChanged = Notification.Name("FixtureLoopKnobChanged")
}
