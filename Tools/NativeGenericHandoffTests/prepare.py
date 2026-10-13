#!/usr/bin/env python3
"""Reuse real native/MPV services while extracting the single-file Core owner."""
from pathlib import Path
import os
import runpy
import sys

root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1])
if os.environ.get("NATIVE_QUEUE_NEGATIVE_CONTROL"):
    raise SystemExit("Queue mutations are not generic handoff controls")
runpy.run_path(str(root / "Tools/NativeCoreQueueTests/prepare.py"), run_name="__main__")
source = (root / "iina/PlayerCore.swift").read_text()
start = source.index("  func fileEnded(")
ended = source[start:source.index("\n  }", start) + 4]
core = (out / "Core.swift").read_text()
core += "\nextension PlayerCore {\n" + ended + "\n}\n"
start = source.index("  func frameStep(")
core += "\nextension PlayerCore {\n" + source[start:source.index("\n  }", start) + 4] + "\n}\n"
start = source.index("  var canAttachExternalPlaybackData:")
core += "\nextension PlayerCore {\n" + source[start:source.index("\n  }", start) + 4] + "\n}\n"
enqueue_accessor = next(line for line in source.splitlines() if "var hasPendingURLPlaylistEnqueue:" in line)
core += "\nextension PlayerCore {\n" + enqueue_accessor + "\n}\n"
window_source = (root / "iina/PlayerWindowController.swift").read_text()
start = window_source.index("  private func handleGuardedPlaybackCommand(")
handler = window_source[start:window_source.index("\n  }", start) + 4].replace("private ", "")
core += """
final class GenericShortcutHarness {
  let player: PlayerCore
  init(_ player: PlayerCore) { precondition(!player.nativePreviewInProgress); self.player = player }
""" + handler + "\n}\n"
negative = os.environ.get("NATIVE_GENERIC_NEGATIVE_CONTROL", "")
mutations = {
    "forget-volume": ("restore.volume = volume", "_ = volume"),
    "forget-speed": ("restore.rate = speed", "_ = speed"),
    "allow-busy-action": ("guard genericHandoffOwner == nil else { return }", "if genericHandoffOwner != nil { completion(); return }"),
    "old-volume-completion": ("guard let self, self.playbackVolumeIntentRevision == intentRevision else { return }", "guard let self else { return }"),
    "old-speed-completion": ("guard let self, self.playbackSpeedIntentRevision == intentRevision else { return }", "guard let self else { return }"),
    "reject-retiring-volume": ("info.state.active || pendingRotationPlaybackRestore != nil else { return }", "info.state.active else { return }"),
    "drop-capture-native-volume": ("if (0...100).contains(volume) { nativeTransport?.setVolumePercent(volume) }", "_ = volume"),
    "drop-capture-native-speed": ("nativeTransport?.setRate(speed)", "_ = speed"),
    "accept-duplicate-start": ("phase == nil || owner.phase == phase else { return false }", "true else { return false }"),
    "drop-typed-seek": ("guard player.isUsingNativePlayback || player.hasPendingGenericPlaybackHandoff || player.videoToolsLoopRange != nil else { return false }\n      switch mode", "guard player.isUsingNativePlayback || player.videoToolsLoopRange != nil else { return false }\n      switch mode"),
    "drop-typed-speed": ("guard player.isUsingNativePlayback || player.hasPendingGenericPlaybackHandoff || player.videoToolsLoopRange != nil else { return false }\n      let current", "guard player.isUsingNativePlayback || player.videoToolsLoopRange != nil else { return false }\n      let current"),
}
if negative:
    if negative not in mutations:
        raise SystemExit("Unknown generic handoff mutation")
    before, after = mutations[negative]
    if core.count(before) != 1:
        raise SystemExit("Generic mutation landmark is not unique")
    core = core.replace(before, after, 1)
(out / "Core.swift").write_text(core)

services = (out / "Services.swift").read_text()
before = '  func emit(_ name: Name, data: String = "") {}'
if services.count(before) != 1:
    raise SystemExit("Event service landmark changed")
services = services.replace(before, '  var onEmit: ((Name) -> Void)?\n  func emit(_ name: Name, data: String = "") { onEmit?(name) }')
services += "\n// No preview panel exists in this scoped typed-command fixture.\nextension QuickSettingDouble { func prepareVideoToolsForUserSeek() {} }\n"
(out / "Services.swift").write_text(services)

# This is an explicit service adapter. Core, transport, decoder, Session and
# all property/command results remain production code or actual libmpv data.
boundary = (root / "Tools/NativeCoreQueueTests/Boundary.swift").read_text()
before = "  var beforeRestart: (() -> Void)?"
boundary = boundary.replace(before, before + "\n  var beforeLoaded: (() -> Void)?\n  var heldLoaded: (() -> Void)?\n  var holdLoaded = false\n  var heldRestart: (() -> Void)?\n  var holdRestart = false")
begin = boundary.index("  func pump() {")
end = boundary.index("  func lockAndSetOpenGLContext()", begin)
pump = '''  func pump() {
    guard let event = mpv_wait_event(client.handle, 0) else { return }
    client.noteQueueEvent(event.pointee.event_id)
    guard let player else { return }
    let revision = player.captureMPVEventRevision()
    switch event.pointee.event_id {
    case MPV_EVENT_START_FILE:
      guard let revision, player.acceptsMPVEventRevision(revision), let path = client.string("path") else { return }
      player.info.state = .starting
      player.fileStarted(path: path)
    case MPV_EVENT_FILE_LOADED:
      guard let revision else { return }
      let deliver = { [weak self] in
        guard let self, let player = self.player, player.acceptsMPVEventRevision(revision) else { return }
        let callback = self.beforeLoaded; self.beforeLoaded = nil; callback?()
        guard player.acceptsMPVEventRevision(revision) else { return }
        player.fileLoaded()
      }
      if holdLoaded { heldLoaded = deliver } else { deliver() }
    case MPV_EVENT_PLAYBACK_RESTART:
      guard let revision else { return }
      let deliver = { [weak self] in
        guard let self, let player = self.player, player.acceptsMPVEventRevision(revision) else { return }
        let callback = self.beforeRestart; self.beforeRestart = nil; callback?()
        guard player.acceptsMPVEventRevision(revision) else { return }
        player.playbackRestarted()
      }
      if holdRestart && player.nativeCompatibilityRestore?.waitingForSeek == true { heldRestart = deliver }
      else { deliver() }
    case MPV_EVENT_VIDEO_RECONFIG:
      if let revision, player.acceptsMPVEventRevision(revision) { player.onVideoReconfig() }
    case MPV_EVENT_END_FILE:
      if let revision, player.acceptsMPVEventRevision(revision) {
        let reason = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee.reason
        player.fileEnded(reason == MPV_END_FILE_REASON_STOP)
      }
    default: break
    }
  }
'''
boundary = boundary[:begin] + pump + boundary[end:]
(out / "Boundary.swift").write_text(boundary)
