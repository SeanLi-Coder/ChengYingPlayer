import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
}
guard let domain = Bundle.main.bundleIdentifier,
      domain.hasPrefix("org.chengying.tests.playback-mode.") else {
  fatalError("The test requires its isolated, randomly named application domain")
}
let defaults = UserDefaults.standard
defaults.register(defaults: ["autoRepeat": false, "defaultRepeatMode": 0])
let task = CommandLine.arguments.dropFirst().first ?? "all"
if task == "cleanup" {
  defaults.removePersistentDomain(forName: domain)
  check(defaults.synchronize(), "Flush isolated domain cleanup")
  exit(0)
}
let modes: [String: LoopMode] = ["file": .file, "playlist": .playlist, "off": .off]
if task.hasPrefix("write-") {
  let mode = modes[String(task.dropFirst(6))]!
  let player = PlayerCore()
  player.setLoopMode(mode)
  check(defaults.synchronize(), "Flush preferences before terminating the writer process")
  print("PASS: Saved \(mode) in isolated process")
  exit(0)
}
if task.hasPrefix("read-") {
  let mode = modes[String(task.dropFirst(5))]!
  let player = PlayerCore()
  player.mpv.properties["loop-file"] = "3"
  player.mpv.properties["loop-playlist"] = "force"
  player.restoreSavedLoopMode()
  check(player.getLoopMode() == mode, "A fresh process and core restore the last chosen mode")
  check(player.mpv.properties["loop-file"] == (mode == .file ? "inf" : "no"), "Restart restores file flag")
  check(player.mpv.properties["loop-playlist"] == (mode == .playlist ? "inf" : "no"), "Restart restores playlist flag")
  print("PASS: Restored \(mode) after process restart")
  exit(0)
}

check(defaults.persistentDomain(forName: domain)?.isEmpty != false, "Begin with an unused preference domain")
check(Preference.savedLoopMode(in: defaults, domain: domain) == nil, "Registered defaults are not an explicit loop choice")
let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
defaults.setVolatileDomain(["autoRepeat": true, "defaultRepeatMode": 1], forName: UserDefaults.argumentDomain)
check(Preference.savedLoopMode(in: defaults, domain: domain) == .file,
      "First-launch Foundation arguments provide an explicit transient loop selection")
let argumentCore = PlayerCore()
argumentCore.restoreSavedLoopMode()
check(argumentCore.getLoopMode() == .file, "A new core applies Foundation arguments without saved repeat keys")
check(defaults.persistentDomain(forName: domain)?.isEmpty != false, "Applying launch arguments does not manufacture saved preferences")
defaults.setVolatileDomain(["autoRepeat": false, "defaultRepeatMode": 1], forName: UserDefaults.argumentDomain)
check(Preference.savedLoopMode(in: defaults, domain: domain) == .off, "An explicit launch argument can disable repetition")
argumentCore.restoreSavedLoopMode()
check(defaults.persistentDomain(forName: domain)?.isEmpty != false, "A transient disabled selection is not saved")
defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
check(Preference.savedLoopMode(in: defaults, domain: domain) == nil, "Removing transient arguments leaves untouched defaults unselected")
let first = PlayerCore()
let second = PlayerCore()
let shuttingDown = PlayerCore()
shuttingDown.info.state = .shuttingDown
PlayerCore.playerCores = [first, second, shuttingDown]
first.mpv.properties["loop-file"] = "3"
first.mpv.properties["loop-playlist"] = "force"
first.restoreSavedLoopMode()
check(first.mpv.writes.isEmpty, "Untouched settings preserve advanced mpv choices")
check(first.getLoopMode() == .file, "Finite mpv file repeats remain visible")
first.mpv.properties["loop-file"] = "no"
check(first.getLoopMode() == .playlist, "Forced mpv playlist repeats remain visible")
let preserved = first.mpv.properties.filter { !$0.key.hasPrefix("loop-") }
for mode in [LoopMode.file, .playlist, .off, .file, .off] {
  first.setLoopMode(mode)
  check(Preference.savedLoopMode(in: defaults, domain: domain) == mode, "Explicit mode is saved globally")
  for player in [first, second] {
    check(player.getLoopMode() == mode, "Every initialized window shares the choice")
    check(player.mpv.properties["loop-file"] == (mode == .file ? "inf" : "no"), "File and playlist flags are exclusive")
    check(player.mpv.properties["loop-playlist"] == (mode == .playlist ? "inf" : "no"), "Playlist and file flags are exclusive")
  }
  let newCore = PlayerCore()
  newCore.restoreSavedLoopMode()
  check(newCore.getLoopMode() == mode, "Subsequently created cores restore the selection")
}
check(shuttingDown.mpv.writes.isEmpty, "Global updates never touch a shutting-down core")
check(first.mpv.properties.filter { !$0.key.hasPrefix("loop-") } == preserved,
      "Mode changes preserve position, pause, speed and all A-B settings")
check(defaults.integer(forKey: "defaultRepeatMode") == 1, "Disabling repeat retains the last enabled settings selection")
let storedBeforeArguments = defaults.persistentDomain(forName: domain)!
defaults.setVolatileDomain(["autoRepeat": true, "defaultRepeatMode": 0], forName: UserDefaults.argumentDomain)
check(Preference.savedLoopMode(in: defaults, domain: domain) == .playlist,
      "Foundation arguments retain precedence over an existing saved selection")
first.restoreSavedLoopMode()
check(first.getLoopMode() == .playlist, "Existing cores apply the transient effective selection")
check(NSDictionary(dictionary: defaults.persistentDomain(forName: domain)!).isEqual(to: storedBeforeArguments),
      "A transient override leaves the complete persisted domain unchanged")
defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
check(Preference.savedLoopMode(in: defaults, domain: domain) == .off,
      "Removing transient arguments reveals the original saved selection")

defaults.set(true, forKey: "autoRepeat")
defaults.set(0, forKey: "defaultRepeatMode")
first.restoreSavedLoopMode()
check(first.getLoopMode() == .playlist, "Legacy preference bindings use the same global selection")
defaults.set(1, forKey: "defaultRepeatMode")
first.restoreSavedLoopMode()
check(first.getLoopMode() == .file, "Legacy file-repeat preferences migrate without new keys")
defaults.set(999, forKey: "defaultRepeatMode")
check(Preference.savedLoopMode(in: defaults, domain: domain) == .playlist, "Unknown enabled legacy values fall back to playlist")
first.setLoopMode(.off)
first.mpv.properties["loop-file"] = "inf"
first.restoreSavedLoopMode()
check(first.getLoopMode() == .off, "Explicit off clears per-file or restored advanced loop options")
check(Preference.savedLoopMode(in: defaults, domain: domain) == .off, "Restoration never saves incidental mpv state")

for property in ["loop", "loop-file", "loop-playlist"] {
  let enabled: LoopMode = property == "loop-playlist" ? .playlist : .file
  for prefix in [[], ["no-osd"], ["osd-msg", "osd-auto"]] {
    check(first.handleLoopModeKeyBinding(prefix + ["cycle-values", property, "\"inf\"", "\"no\""]), "Recognize bundled repeat shortcuts")
    check(first.getLoopMode() == enabled, "A repeat shortcut enables its mode")
    check(first.handleLoopModeKeyBinding(prefix + ["cycle-values", property, "'inf'", "'no'"]), "Accept quoted shortcut values")
    check(first.getLoopMode() == .off, "The next shortcut invocation disables and saves repeat")
  }
  check(first.handleLoopModeKeyBinding(["set", property, "inf"]) && first.getLoopMode() == enabled, "Persist explicit set shortcuts")
  check(first.handleLoopModeKeyBinding(["cycle", property, "down"]) && first.getLoopMode() == .off, "Persist cycle shortcuts")
  check(first.handleLoopModeKeyBinding(["cycle-values", "!reverse", property, "inf", "no"]), "Accept reverse cycle flag before the property")
  first.setLoopMode(.off)
}
for command in [["ab-loop"], ["set", "ab-loop-a", "2"], ["set", "loop-file", "3"],
                ["cycle-values", "loop-file", "2", "no"], ["set", "loop-file", "inf;", "seek", "0"],
                ["cycle-values", "loop-file", "inf", "no", ";", "quit"]] {
  check(!first.handleLoopModeKeyBinding(command), "Leave unrelated, compound and finite repeat commands in mpv")
}
check(Preference.savedLoopMode(in: defaults, domain: domain) == .off, "Unrecognized commands cannot change saved mode")
first.setLoopMode(.playlist)
check(first.handleLoopModeKeyBinding(["set", "loop-file", "no"]) && first.getLoopMode() == .playlist,
      "Disabling an already-off file flag preserves active playlist repetition")
first.setLoopMode(.file)
check(first.handleLoopModeKeyBinding(["set", "loop-playlist", "0"]) && first.getLoopMode() == .file,
      "Disabling an already-off playlist flag preserves active file repetition")
first.setLoopMode(.off)

let hook = HookController(first)
hook.addSavedLoopModeHook()
check(Set(hook.hooks.keys) == [MPVHook.onPreLoaded.rawValue, MPVHook.onAfterEndFile.rawValue],
      "Register both file-load and completed-teardown restoration barriers")
first.mpv.properties["loop-file"] = "inf"
var continued = false
hook.hooks[MPVHook.onPreLoaded.rawValue]!.block { continued = true }
let deadline = Date().addingTimeInterval(2)
while !continued && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
check(continued && first.getLoopMode() == .off, "The production preloaded hook applies saved off before continuing playback")
first.setLoopMode(.playlist)
first.mpv.properties["loop-file"] = "2"
first.mpv.properties["loop-playlist"] = "no"
continued = false
hook.hooks[MPVHook.onPreLoaded.rawValue]!.block { continued = true }
while !continued && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
check(continued && first.getLoopMode() == .playlist, "The hook reads the latest global choice on each automatic file load")
first.mpv.properties["loop-file"] = "inf"
first.mpv.properties["loop-playlist"] = "no"
continued = false
hook.hooks[MPVHook.onAfterEndFile.rawValue]!.block { continued = true }
while !continued && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
check(continued && first.getLoopMode() == .playlist,
      "Completed-teardown restoration replaces stale file-local backups before playlist selection")
check(Preference.savedLoopMode(in: defaults, domain: domain) == .playlist,
      "Completed-teardown restoration cannot overwrite the saved choice")
first.info.state = .shuttingDown
first.mpv.writes.removeAll()
continued = false
var shutdownContinuations = 0
hook.hooks[MPVHook.onAfterEndFile.rawValue]!.block {
  shutdownContinuations += 1
  continued = true
}
while !continued && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
check(shutdownContinuations == 1 && first.mpv.writes.isEmpty,
      "A hook arriving during shutdown completes exactly once without touching mpv properties")
var releasedController: HookController? = HookController(first)
releasedController!.addSavedLoopModeHook()
let releasedHook = releasedController!.hooks[MPVHook.onAfterEndFile.rawValue]!
weak var weakController = releasedController
releasedController = nil
check(weakController == nil, "Restoration hooks do not retain their controller")
var releasedContinuations = 0
releasedHook.block { releasedContinuations += 1 }
while releasedContinuations == 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
check(releasedContinuations == 1 && first.mpv.writes.isEmpty,
      "A released controller still completes its queued teardown hook exactly once")
defaults.removePersistentDomain(forName: domain)
check(defaults.synchronize(), "Flush isolated fixture cleanup")
print("PASS: \(checks) playback mode persistence and production wiring checks")
