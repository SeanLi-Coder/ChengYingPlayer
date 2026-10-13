#!/usr/bin/env python3
"""Actual Core/receipt/store with explicit isolated application services."""
from pathlib import Path
import os
import runpy
import sys

root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1])
runpy.run_path(str(root / "Tools/NativeGenericHandoffTests/prepare.py"), run_name="__main__")


def replace_once(text, before, after):
    if text.count(before) != 1:
        raise SystemExit("Resume extraction landmark is not unique: " + before[:80])
    return text.replace(before, after, 1)


core = (out / "Core.swift").read_text()
core = replace_once(core,
    '    let defaults = UserDefaults(suiteName: "NativeResumeFixture." + UUID().uuidString)!\n'
    '    defaults.setVolatileDomain(["resumeLastPosition": false], forName: UserDefaults.argumentDomain)',
    '    let defaults = resumeFixtureDefaults')
negative = os.environ.get("NATIVE_RESUME_CORE_NEGATIVE", "none")
mutations = {
    "drop-exit-save": (
        "    let savedByNative = requestNativeResumeSave()\n    invalidateGenericHandoff()\n    let cancelledQueueOwner",
        "    let savedByNative = false\n    invalidateGenericHandoff()\n    let cancelledQueueOwner"),
    "drop-preview-checkpoint": (
        "nativeResumePreviewCheckpoint = restorePlaybackState ? baseline : nil",
        "nativeResumePreviewCheckpoint = nil"),
}
if negative != "none":
    if negative not in mutations:
        raise SystemExit("Unknown resume Core mutation")
    core = replace_once(core, *mutations[negative])
(out / "Core.swift").write_text(core)

services = (out / "Services.swift").read_text()
services = "import CryptoKit\n" + services
services += '''
let resumeFixtureDomain = "NativeResumeCore." + UUID().uuidString
let resumeFixtureDefaults: UserDefaults = {
  let defaults = UserDefaults(suiteName: resumeFixtureDomain)!
  precondition(defaults.persistentDomain(forName: resumeFixtureDomain) == nil)
  let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
  try! Data((resumeFixtureDomain + "\\n").utf8).write(to: root.appendingPathComponent("owned-domain.txt"))
  defaults.register(defaults: ["resumeLastPosition": true])
  return defaults
}()
'''
services = replace_once(services, "    case .pauseWhenOpen: return pauseWhenOpen",
    '    case .resumeLastPosition: return resumeFixtureDefaults.bool(forKey: "resumeLastPosition")\n'
    "    case .pauseWhenOpen: return pauseWhenOpen")
services = replace_once(services,
    '  static func mpvWatchLaterMd5(_ path: String) -> String { "synthetic-file-only" }',
    '''  static func mpvWatchLaterMd5(_ path: String) -> String {
    Insecure.MD5.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
  }''')
(out / "Services.swift").write_text(services)

boundary = (out / "Boundary.swift").read_text()
boundary = replace_once(boundary, "  func mpvQuit() { quitCalls += 1 }", '''  var actualShutdownReceived = false
  func mpvQuit() { quitCalls += 1; _ = client.queueCommand(["quit"]) }''')
boundary = replace_once(boundary, "  func pump() {", "  func pump() {\n    guard !actualShutdownReceived else { return }")
boundary = replace_once(boundary, "    switch event.pointee.event_id {", '''    switch event.pointee.event_id {
    case MPV_EVENT_SHUTDOWN: actualShutdownReceived = true''')
(out / "Boundary.swift").write_text(boundary)
client = (root / "Tools/MPVQueueInstallerTests/LiveClient.swift").read_text()
client = replace_once(client, '"resume-playback": "no", "cache": "no"',
    '"resume-playback": "yes", "watch-later-directory": Utility.watchLaterURL.path, "cache": "no"')
(out / "LiveClient.swift").write_text(client)
