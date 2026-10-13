"""Extract actual preference entry points; Core delivery is a recording boundary."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1])
mode = sys.argv[2] if len(sys.argv) > 2 else ""
source = (root / "iina/MPVController.swift").read_text()
prefs = (root / "iina/PrefCodecViewController.swift").read_text()
core = (root / "iina/PlayerCore.swift").read_text()

def member(text, signature):
    start = text.index(signature)
    return text[start:text.index("\n  }", start) + 4]

observer = member(source, "  override func observeValue(")
if mode == "direct-observer":
    start = observer.index("    if keyPath == PK.audioDevice.rawValue {")
    end = observer.index("\n    }", start) + 6
    observer = observer[:start] + observer[end:]
declarations = source[source.index("  private enum UserOptionType"):source.index("  private func setOptionFlag(")]
helpers = ""
if "  private func audioDevicePreferenceDidChange()" in source:
    for signature in ("  private func audioDevicePreferenceDidChange()", "  private func applyPendingAudioDevicePreference(",
                      "  private func scheduleAudioDevicePreference(", "  private func cancelPendingAudioDevicePreference()"):
        helpers += member(source, signature) + "\n"
action = member(prefs, "  @IBAction func audioDeviceAction(")
popup = member(prefs, "  private func updateAudioDevicePopUp()")
if mode == "drop-ui-guard":
    start = action.index("    guard PlayerCore.playerCores")
    end = action.index("\n    }\n    let device", start) + 6
    action = action[:start] + action[end:]
gate = member(core, "  var canSelectAudioDevice:")
if mode == "drop-inventory-guard":
    old = "      (nativeTransport != nil || playbackEventRoute.acceptsMPV) &&\n"
    if gate.count(old) != 1: raise SystemExit("Inventory mutation anchor changed")
    gate = gate.replace(old, "", 1)
if mode == "drop-shutdown-guard":
    old = "guard mpv != nil, !hasReceivedShutdown,"
    if helpers.count(old) != 1: raise SystemExit("Shutdown mutation anchor changed")
    helpers = helpers.replace(old, "guard mpv != nil,", 1)
if mode == "retry-native":
    start = helpers.index("    if requiresHandoff && audioDevicePreferenceAttemptedNative {")
    end = helpers.index("\n    }", start) + 6
    helpers = helpers[:start] + helpers[end:]
if mode not in ("", "direct-observer", "drop-ui-guard", "drop-inventory-guard", "drop-shutdown-guard", "retry-native"):
    raise SystemExit("Unknown mutation")
generated = '''import AppKit
final class PreferenceObserverHarness: NSObject {
  let player: PlayerCore
  var mpv: Int? = 1
  typealias PK = Preference.Key
  var writes: [String] = []
  var diagnostics: [String] = []
  init(_ player: PlayerCore) {
    self.player = player
    super.init()
    optionObservers[PK.audioDevice.rawValue] = [OptionObserverInfo(.audioDevice, "audio-device", .other, { _ in Preference.effectiveAudioDeviceName })]
    Preference.store.addObserver(self, forKeyPath: PK.audioDevice.rawValue, options: [.old, .new], context: nil)
  }
  deinit {
    Preference.store.removeObserver(self, forKeyPath: PK.audioDevice.rawValue)
    DEINIT_CANCEL
  }
  func setString(_ name: String, _ value: String) { precondition(name == "audio-device"); writes.append(value) }
  func setInt(_ name: String, _ value: Int) { preconditionFailure("Unrelated option") }
  func setDouble(_ name: String, _ value: Double) { preconditionFailure("Unrelated option") }
  func setFlag(_ name: String, _ value: Bool) { preconditionFailure("Unrelated option") }
  func log(_ text: String, level: Logger.Level) {
    precondition(level == .warning && text == "Audio device preference was not applied; saved preference retained for the next media open")
    diagnostics.append(text)
  }
'''.replace("DEINIT_CANCEL", "audioDevicePreferenceWorkItem?.cancel()" if helpers else "")
shutdown_flag = next(line for line in source.splitlines() if "@Atomic private var hasReceivedShutdown = false" in line)
generated += shutdown_flag + "\n" + declarations + helpers + observer + "\n}\n"
generated += "extension PlayerCore {\n" + gate + "\n}\n"
generated += "final class PreferencePaneHarness: NSObject {\n let audioDevicePopUp = NSPopUpButton()\n let view = NSView()\n" + action + "\n" + popup + "\n}\n"
(out / "Extracted.swift").write_text(generated.replace("private ", ""))
