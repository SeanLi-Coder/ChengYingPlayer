#!/usr/bin/env python3
"""Extract actual Core queue restoration with isolated watch-later services."""
from pathlib import Path
import os
import runpy
import sys

root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1])
runpy.run_path(str(root / "Tools/NativeCoreQueueTests/prepare.py"), run_name="__main__")


def once(source, before, after):
    if source.count(before) != 1:
        raise SystemExit(f"Expected one fixture landmark: {before!r}")
    return source.replace(before, after, 1)


control = os.environ.get("NATIVE_QUEUE_RESUME_NEGATIVE_CONTROL", "")
mutations = {
    "unopened-origin": ("    restore.restoresMPVWatchLater = true", "    restore.restoresMPVWatchLater = false"),
    "forget-saved-speed": ("    restore.speedIntentChanged = false", "    restore.speedIntentChanged = true"),
    "forget-speed-intent": ("    restore.speedIntentChanged = true", "    _ = speed"),
    "forget-seek-upgrade": ("      restore.restoresMPVWatchLater = false", "      _ = position"),
    "captured-rate-not-authoritative": ("    var speedIntentChanged = true", "    var speedIntentChanged = false"),
}
if control:
    if control not in mutations:
        raise SystemExit("Unknown queue resume control")
    before, after = mutations[control]
    (out / "Core.swift").write_text(once((out / "Core.swift").read_text(), before, after))


services = (out / "Services.swift").read_text()
services = "import CryptoKit\n" + services
services = once(services, "  static var pauseWhenOpen = false", "  static var pauseWhenOpen = false\n  static var resumeLastPosition = true")
services = once(services, "    case .pauseWhenOpen: return pauseWhenOpen", "    case .pauseWhenOpen: return pauseWhenOpen\n    case .resumeLastPosition: return resumeLastPosition")
# Match the production lowercase MD5 convention without importing unrelated
# application extensions. Actual MPV creates/consumes the file; the test checks
# this exact admission path exists on the test filesystem before opening Core.
services = once(services, '  static func mpvWatchLaterMd5(_ path: String) -> String { "synthetic-file-only" }',
                '  static func mpvWatchLaterMd5(_ path: String) -> String { Insecure.MD5.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() }')
(out / "Services.swift").write_text(services)

client = (root / "Tools/MPVQueueInstallerTests/LiveClient.swift").read_text()
client = once(client, '"resume-playback": "no", "cache": "no"',
              '"resume-playback": "yes", "cache": "no", "watch-later-directory": directory.appendingPathComponent("watch-later").path, "write-filename-in-watch-later-config": "no"')
(out / "LiveClient.swift").write_text(client)

boundary = (root / "Tools/NativeCoreQueueTests/Boundary.swift").read_text()
boundary = once(boundary, "  var beforeRestart: (() -> Void)?", """  var beforeRestart: (() -> Void)?
  var beforeLoaded: (() -> Void)?
  var commandArguments = [[String]]()
  var actualRestarts = 0
""")
boundary = once(boundary, "  func queueCommand(_ arguments: [String]) -> Int32? {", """  func queueCommand(_ arguments: [String]) -> Int32? {
    commandArguments.append(arguments)
""")
boundary = once(boundary, "    case MPV_EVENT_FILE_LOADED:\n      let id = contextEntryID", """    case MPV_EVENT_FILE_LOADED:
      let callback = beforeLoaded; beforeLoaded = nil; callback?()
      let id = contextEntryID""")
boundary = once(boundary, "    case MPV_EVENT_PLAYBACK_RESTART:\n", "    case MPV_EVENT_PLAYBACK_RESTART:\n      actualRestarts += 1\n")
(out / "Boundary.swift").write_text(boundary)
