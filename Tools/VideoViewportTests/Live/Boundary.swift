import Foundation

// Only the unrelated application shell is replaced. The production shortcut
// resolver, viewport model, and PlayerCore bridge execute unchanged against mpv.
final class PlayerCore {
  final class Info {
    struct State { var loaded = true }
    var state = State()
    var vid: Int? = 1
  }
  let info = Info()
  let mpv = LiveMPV()
}

final class LiveMPV {
  private(set) var writes: [String] = []

  func getDouble(_ name: String) -> Double {
    var result = 0.0
    guard viewport_live_get_double(name, &result) else {
      fatalError("The live player could not read a viewport property")
    }
    return result
  }

  func setDouble(_ name: String, _ value: Double) {
    writes.append(name)
    guard viewport_live_set_double(name, value) else {
      fatalError("The live player could not set a viewport property")
    }
  }
}
