#!/usr/bin/env python3
"""Extract real drop/admission methods around the real generic handoff fixture."""
from pathlib import Path
import os
import runpy
import sys

root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1])
runpy.run_path(str(root / "Tools/NativeGenericHandoffTests/prepare.py"), run_name="__main__")
core_source = (root / "iina/PlayerCore.swift").read_text()
drop_source = (root / "iina/DraggingDetect.swift").read_text()
utility_source = (root / "iina/Utility.swift").read_text()

def method(source, signature):
    start = source.index(signature)
    return source[start:source.index("\n  }", start) + 4]

def replace_once(text, before, after):
    if text.count(before) != 1:
        raise SystemExit(f"Non-unique fixture landmark: {before!r}")
    return text.replace(before, after, 1)

core = (out / "Core.swift").read_text()
# Exercise actual enqueue ownership rather than the inherited no-enqueue service.
no_enqueue = (root / "Tools/NativePlayerCoreTests/NoURLPlaylistBoundary.txt").read_text().replace("private ", "")
start = core_source.index("  private struct URLPlaylistRequest")
end = core_source.index("  func appendToPlaylist(", start)
core = replace_once(core, no_enqueue, core_source[start:end].replace("private ", ""))
core = replace_once(core, "  func openFromPasteboard(_ sender: NSDraggingInfo) -> Bool { false }", "")
core += "\nextension PlayerCore {\n" + "\n".join([
    method(core_source, "  func openURLs("),
    method(core_source, "  func loadExternalSubFile("),
    method(core_source, "  func addVideoFilter(_ filter: String)"),
    method(drop_source, "  func openFromPasteboard("),
]) + "\n}\n"
core += "\nextension PlayerCore {\n" + next(line for line in core_source.splitlines()
                                          if "  func addVideoFilter(_ filter: MPVFilter)" in line) + "\n}\n"
core = replace_once(core, "final class PlayerCore {", """final class PlayerCore {
  @Atomic var expectedFolderMatchURL: URL?
  @Atomic var folderMatchRequests: [URL] = []
""")
if "  var canAttachExternalPlaybackData:" in core_source:
    core += "\nextension PlayerCore {\n" + method(core_source, "  var canAttachExternalPlaybackData:") + "\n}\n"
negative = os.environ.get("NATIVE_SUBTITLE_NEGATIVE_CONTROL", "")
if negative:
    if negative == "early-invalidation":
        start = core.index("  func openMediaURLs(")
        end = core.index("\n  }", start) + 4
        body = core[start:end]
        body = replace_once(body, "    invalidateGenericHandoff()\n", "")
        body = replace_once(body, "    playlistMutationLock.lock()", "    invalidateGenericHandoff()\n    playlistMutationLock.lock()")
        core = core[:start] + body + core[end:]
    elif negative in ["allow-busy-subtitle", "allow-busy-lut"]:
        gate = "        guard canAttachExternalPlaybackData else { return false }\n"
        if negative == "allow-busy-subtitle":
            comment = "        // Reject this drop without replacing the existing restore/action owner.\n"
            core = replace_once(core, comment + gate, comment)
        else:
            core = replace_once(core, "        guard canAttachExternalPlaybackData else { return false }\n        // Copy", "        // Copy")
    elif negative == "reject-new-media":
        core = replace_once(core, "    // Subtitle attachments and other non-playable inputs are not a new media",
                            "    if hasPendingGenericPlaybackHandoff { return 0 }\n    // Subtitle attachments and other non-playable inputs are not a new media")
    elif negative == "remove-inventory-gate":
        core = replace_once(core, "      (nativeTransport != nil || playbackEventRoute.acceptsMPV) &&\n", "")
    else:
        raise SystemExit("Unknown subtitle negative control")
(out / "Core.swift").write_text(core)

services = (out / "Services.swift").read_text()
services = replace_once(services, "var audioTracks: [Int] = [], videoTracks: [Int] = [], subTracks: [Int] = [], chapters: [Int] = []",
                        "var audioTracks: [Int] = [], videoTracks: [Int] = [], chapters: [Int] = []\n  @Atomic var subTracks: [MPVTrack] = []")
services = replace_once(services, "enum ExtensionType { case video, sub }", "enum ExtensionType { case video, audio, sub }")
services = replace_once(services, "enum Key {", "enum Key { case hardwareDecoder\n")
start = utility_source.index("  static let supportedFileExt:")
end = utility_source.index("\n\n  /// Accept paths", start)
extensions = utility_source[start:end].replace("MPVTrack.TrackType", "ExtensionType")
start = services.index("  static let supportedFileExt:")
end = services.index("  static var watchLaterURL", start)
services = services[:start] + extensions + "\n" + services[end:]
services = replace_once(services, "case custom(String), addToPlaylist(Int), speed(Double)",
                        "case custom(String), addToPlaylist(Int), speed(Double), addFilter(String)")
services += "\nextension Utility {\n" + method(utility_source, "  static func resolvePaths(") + "\n" + method(utility_source, "  static func resolveURLs(") + "\n}\n"
services += "\nextension String {\n" + method((root / "iina/Extensions.swift").read_text(), "  var mpvFixedLengthQuoted:") + "\n}\n"
services += "\nextension Array {\n" + method((root / "iina/Extensions.swift").read_text(), "  subscript(at index:") + "\n}\n"
image_source = (root / "iina/ImageViewer/ImageViewerCoordinator.swift").read_text()
services += "\n" + image_source[image_source.index("struct ImageOpenPlan {"):image_source.index("/// Keep image windows")]
(out / "Services.swift").write_text(services)

boundary = (out / "Boundary.swift").read_text()
boundary = replace_once(boundary, '  static let playlistFileExt: Set<String> = ["m3u", "m3u8"]\n', "")
start = boundary.index("  func getPlayableFiles(")
end = boundary.index("\n  }", start) + 4
boundary = boundary[:start] + method(drop_source, "  func getPlayableFiles(") + boundary[end:]
boundary = replace_once(boundary, '  func loadExternalSubFile(_ url: URL) { preconditionFailure("No external subtitles in this fixture") }\n', "")
boundary = replace_once(boundary, '  func autoLoadFilesInCurrentFolder(ticket: Int) throws { preconditionFailure("Explicit queue must not invoke folder matcher") }', '''  func autoLoadFilesInCurrentFolder(ticket: Int) throws {
    guard let expected = expectedFolderMatchURL, expected == fixtureDirectory.appendingPathComponent("blue.mp4"),
          info.currentURL == expected, info.shouldAutoLoadFiles,
          Preference.bool(for: .playlistAutoAdd), Preference.integer(for: .subAutoLoadIINA) == 0 else {
      preconditionFailure("Only the explicitly authorized single new-media drop may request folder matching")
    }
    expectedFolderMatchURL = nil
    $folderMatchRequests.withLock { requests in
      precondition(requests.isEmpty, "The authorized folder request must occur exactly once")
      requests.append(expected)
    }
    // Record the one admitted application service request. Folder discovery and
    // sibling/subtitle insertion have their own tests; neither is faked here.
  }''')
# Queue installation forwards its own actual events until it returns ownership.
original = (root / "Tools/NativeCoreQueueTests/Boundary.swift").read_text()
queue_pump = method(original, "  func pump() {").replace("func pump()", "func pumpQueueInstallation()")
queue_pump = replace_once(queue_pump, "      if let receiver, let id { receiver(.fileLoaded(entryID: id)) }", """      if let receiver, let id {
        let deliver = { receiver(.fileLoaded(entryID: id)) }
        if holdLoaded { heldLoaded = deliver } else { deliver() }
      }""")
boundary = replace_once(boundary, "  func pump() {", "  func pump() {\n    if receiver != nil { pumpQueueInstallation(); return }")
boundary += "\nextension MPVController {\n" + queue_pump + "\n}\n"
boundary += "\n" + (root / "Tools/NativeSubtitleDropTests/Boundary.swift").read_text()
(out / "Boundary.swift").write_text(boundary)
