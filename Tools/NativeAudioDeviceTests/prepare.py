#!/usr/bin/env python3
"""Extract actual audio-device entry points over real native and MPV services."""
from pathlib import Path
import os
import runpy
import sys

root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1])
runpy.run_path(str(root / "Tools/NativeGenericHandoffTests/prepare.py"), run_name="__main__")
source = (root / "iina/PlayerCore.swift").read_text()

def member(source, signature):
    start = source.index(signature)
    return source[start:source.index("\n  }", start) + 4]

core = (out / "Core.swift").read_text()
members = [member(source, "  func setAudioDevice(")]
enqueue_accessor = next(line for line in source.splitlines() if "var hasPendingURLPlaylistEnqueue:" in line)
if enqueue_accessor not in core:
    members.append(enqueue_accessor)
for signature in ["  var canSelectAudioDevice:", "  var currentAudioDeviceName:"]:
    if signature in source:
        members.append(member(source, signature))
core += "\nextension PlayerCore {\n" + "\n".join(members) + "\n}\n"
menu = member((root / "iina/MenuController.swift").read_text(), "  private func updateAudioDevice()")
menu = menu.replace("private ", "")
action = member((root / "iina/AppDelegate.swift").read_text(), "  @IBAction func menuSelectAudioDevice(")
core += "\nextension AppDelegate {\n" + action + "\n}\n"
core += "\nfinal class AudioMenuHarness {\n  let audioDeviceMenu = NSMenu()\n" + menu + "\n}\n"
core += '''
// Enumeration is a fixed service boundary, not a claim of physical hardware.
extension PlayerCore {
  static var active: PlayerCore { lastActive! }
  func getAudioDevices() -> [MPVAudioDevice] {
    [MPVAudioDevice(desc: "System default", name: "auto"),
     MPVAudioDevice(desc: "Unavailable test device", name: "coreaudio/test-device")]
  }
}
enum ImageViewerCoordinator { static var blocksPlaybackMenu = false }
'''
extensions = (root / "iina/Extensions.swift").read_text()
core += "\nextension NSMenu {\n" + member(extensions, "  func addItem(withTitle string:") + "\n}\n"
negative = os.environ.get("NATIVE_AUDIO_DEVICE_NEGATIVE_CONTROL", "")
if negative == "direct-idle-write":
    actual = member(core, "  func setAudioDevice(")
    core = core.replace(actual, '  func setAudioDevice(_ name: String) {\n    mpv.setString(MPVProperty.audioDevice, name)\n  }', 1)
elif negative == "idle-menu-state":
    before = "let currAudioDevice = player.currentAudioDeviceName"
    if core.count(before) != 1:
        raise SystemExit("Audio menu mutation landmark is not unique")
    core = core.replace(before, "let currAudioDevice = player.mpv.getString(MPVProperty.audioDevice)", 1)
elif negative == "drop-busy-guard":
    actual = member(core, "  func setAudioDevice(")
    before = "    guard canSelectAudioDevice else { return }\n"
    if actual.count(before) != 1:
        raise SystemExit("Audio device busy mutation landmark is not unique")
    core = core.replace(actual, actual.replace(before, "", 1), 1)
elif negative:
    raise SystemExit("Unknown audio-device mutation")
(out / "Core.swift").write_text(core)

boundary = (out / "Boundary.swift").read_text().replace("final class AppDelegate {", "final class AppDelegate: NSObject {")
# Retain the queue installer's real event forwarding in addition to the generic
# fixture's explicit hold/release adapter. No MPV event is fabricated here.
original = (root / "Tools/NativeCoreQueueTests/Boundary.swift").read_text()
queue_pump = member(original, "  func pump() {").replace("func pump()", "func pumpQueueInstallation()")
before = "      if let receiver, let id { receiver(.fileLoaded(entryID: id)) }"
if queue_pump.count(before) != 1:
    raise SystemExit("Queue loaded event landmark changed")
queue_pump = queue_pump.replace(before, '''      if let receiver, let id {
        let deliver = { receiver(.fileLoaded(entryID: id)) }
        if holdLoaded { heldLoaded = deliver } else { deliver() }
      }''', 1)
boundary = boundary.replace("  func pump() {", "  func pump() {\n    if receiver != nil { pumpQueueInstallation(); return }", 1)
before = "    case MPV_EVENT_START_FILE:"
idle_event = '''    case MPV_EVENT_PROPERTY_CHANGE:
      guard let revision, player.acceptsMPVEventRevision(revision),
            let raw = event.pointee.data else { return }
      let property = raw.assumingMemoryBound(to: mpv_event_property.self).pointee
      if let name = property.name, String(cString: name) == "idle-active",
         property.format == MPV_FORMAT_FLAG, let data = property.data,
         data.assumingMemoryBound(to: Int32.self).pointee != 0 {
        player.idleActiveChanged()
      }
'''
boundary = boundary.replace(before, idle_event + before, 1)
boundary += "\nextension MPVController {\n" + queue_pump + "\n}\n"
(out / "Boundary.swift").write_text(boundary)
