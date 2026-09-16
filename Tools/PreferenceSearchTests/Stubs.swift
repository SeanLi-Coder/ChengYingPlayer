import Cocoa

let IINA_ENABLE_PLUGIN_SYSTEM = false

enum AccessibilityPreferences {
  static func adjustedDuration(_ duration: TimeInterval) -> TimeInterval { duration }
}

enum Utility {
  static func quickConstraints(_ formats: [String], _ views: [String: NSView]) {
    for view in views.values { view.translatesAutoresizingMaskIntoConstraints = false }
    NSLayoutConstraint.activate(formats.flatMap {
      NSLayoutConstraint.constraints(withVisualFormat: $0, options: [], metrics: nil, views: views)
    })
  }
}

extension Array {
  subscript(at index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension NSImage {
  static func findSFSymbol(_ names: [String], withConfiguration configuration: NSImage.SymbolConfiguration) -> NSImage {
    NSImage(systemSymbolName: names[0], accessibilityDescription: nil)!.withSymbolConfiguration(configuration)!
  }
}

extension NSBox {
  static func horizontalLine() -> NSBox {
    let box = NSBox()
    box.boxType = .separator
    return box
  }
}

final class PrefPluginViewController: PreferenceViewController, PreferenceWindowEmbeddable {
  var preferenceTabTitle: String { "Unavailable" }
  var preferenceTabImage: NSImage { NSImage() }
  func installPluginAction(localPackageURL: URL) {}
}
