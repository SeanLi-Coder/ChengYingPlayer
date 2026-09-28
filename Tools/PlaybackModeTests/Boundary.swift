import Foundation

enum MPVOption {
  enum PlaybackControl {
    static let loopFile = "loop-file"
    static let loopPlaylist = "loop-playlist"
  }
}

final class InfoFixture { var state: PlayerState = .idle }

final class MPVFixture {
  var mpv: Int? = 1
  var properties = ["loop-file": "no", "loop-playlist": "no", "ab-loop-a": "2", "ab-loop-b": "7",
                    "ab-loop-count": "inf", "pause": "yes", "speed": "1.5", "time-pos": "4"]
  var writes: [(String, String)] = []
  func getString(_ name: String) -> String? { properties[name] }
  func setString(_ name: String, _ value: String) {
    properties[name] = value
    writes.append((name, value))
  }
}

struct MPVHookValue {
  let block: (@escaping () -> Void) -> Void
  init(withBlock block: @escaping (@escaping () -> Void) -> Void) { self.block = block }
}

class HookFixture {
  let player: PlayerCore
  var hooks: [String: MPVHookValue] = [:]
  init(_ player: PlayerCore) { self.player = player }
  func addHook(_ name: MPVHook, priority: Int32, hook: MPVHookValue) {
    precondition([MPVHook.onPreLoaded.rawValue, MPVHook.onAfterEndFile.rawValue].contains(name.rawValue) && priority == 100)
    precondition(hooks[name.rawValue] == nil)
    hooks[name.rawValue] = hook
  }
}
