import Cocoa

/// Shared rules for the edge controls, including upgrades from floating controls.
enum PlayerChromePolicy {
  static let migrationKey = "chengyingEdgeControlsVersion"

  static func migratePreferences(_ defaults: UserDefaults) {
    guard defaults.integer(forKey: migrationKey) < 1 else { return }
    // Updating the default appearance must not reset existing or launch-time choices.
    let initialValues: [String: Any] = [
      "oscPosition": 2,
      "enableControlBarAutoHide": true,
      "showRemainingTime": true,
    ]
    for (key, value) in initialValues where defaults.object(forKey: key) == nil {
      defaults.set(value, forKey: key)
    }
    defaults.set(1, forKey: migrationKey)
  }

  static func contains(_ point: NSPoint, in view: NSView?, window: NSWindow?) -> Bool {
    guard let view, let window, view.window === window,
          !view.isHiddenOrHasHiddenAncestor else { return false }
    var ancestor: NSView? = view
    while let current = ancestor {
      guard current.alphaValue > 0.01 else { return false }
      ancestor = current.superview
    }
    let local = view.convert(point, from: nil)
    // Unclipped AppKit views can report a visibleRect larger than their own bounds.
    let interactiveRect = view.bounds.intersection(view.visibleRect)
    return !interactiveRect.isEmpty && view.isMousePoint(local, in: interactiveRect)
  }

  static func hideDelay(_ configured: Double) -> TimeInterval {
    configured.isFinite ? min(max(configured, 0.5), 60) : 2.5
  }
}
