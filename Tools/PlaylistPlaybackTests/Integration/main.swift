import Foundation

enum IINAError: Error {
  case unsupportedMPVNodeFormat(UInt32)
}

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ description: String) {
  guard condition() else { fatalError("FAIL: \(description)") }
  checks += 1
}

guard let handle = mpv_create() else { fatalError("Unable to create the actual libmpv core") }
defer { mpv_terminate_destroy(handle) }
for (key, value) in ["vo": "null", "ao": "null", "pause": "yes", "idle": "yes", "keep-open": "yes", "terminal": "no"] {
  check(mpv_set_option_string(handle, key, value) >= 0, "Configure headless libmpv: \(key)")
}
check(mpv_initialize(handle) >= 0, "Initialize the actual bundled libmpv")

func command(_ arguments: [String]) -> Bool {
  let buffers = arguments.map { strdup($0)! }
  defer { buffers.forEach { free($0) } }
  var pointers: [UnsafePointer<CChar>?] = buffers.map { UnsafePointer($0) }
  pointers.append(nil)
  return mpv_command(handle, &pointers) >= 0
}

func snapshot() -> [MPVPlaylistItem]? {
  var node = mpv_node()
  guard mpv_get_property(handle, "playlist", MPV_FORMAT_NODE, &node) >= 0 else { return nil }
  defer { mpv_free_node_contents(&node) }
  return MPVPlaylistItem.playlist(from: try? MPVNode.parse(node))
}

func number(_ name: String) -> Double {
  var value: Double = .nan
  _ = mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value)
  return value
}

func flag(_ name: String) -> Bool {
  var value: Int32 = 0
  _ = mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value)
  return value != 0
}

func events(for interval: TimeInterval) -> [mpv_event_id] {
  let deadline = Date().addingTimeInterval(interval)
  var result: [mpv_event_id] = []
  repeat {
    let event = mpv_wait_event(handle, max(0, deadline.timeIntervalSinceNow))!.pointee.event_id
    if event != MPV_EVENT_NONE { result.append(event) }
  } while Date() < deadline
  return result
}

func reorder(_ desired: [MPVPlaylistItem]) -> Bool {
  return PlaylistPlaybackPolicy.reorder(to: desired.map(\.entryID),
    expectedIDs: desired.first?.snapshotEntryIDs ?? [], readIDs: { snapshot()?.map(\.entryID) }, move: { step in
      command(["playlist-move", String(step.from), String(step.to)])
    })
}

let path = CommandLine.arguments[1]
check(command(["loadfile", path]), "Load a real local video")
let deadline = Date().addingTimeInterval(10)
var loaded = false
while Date() < deadline && !loaded {
  loaded = mpv_wait_event(handle, 0.1)!.pointee.event_id == MPV_EVENT_FILE_LOADED
}
check(loaded, "The video decoder loaded successfully")
check(command(["seek", "3", "absolute+exact"]), "Seek to an interior playback position")
_ = events(for: 0.5)
for _ in 0..<3 { check(command(["loadfile", path, "append"]), "Append a duplicate path as a distinct entry") }
for (key, value) in ["ab-loop-a": "2", "ab-loop-b": "8", "speed": "1.7"] {
  check(mpv_set_property_string(handle, key, value) >= 0, "Configure preserved playback state: \(key)")
}
_ = events(for: 0.1)
let before = snapshot()!
let currentID = before.first(where: \.isPlaying)!.entryID
let beforePosition = number("time-pos")
check(before.count == 4 && Set(before.map(\.entryID)).count == 4, "Real mpv assigns unique IDs to duplicate paths")
check(beforePosition >= 2.9 && beforePosition < 3.2, "The real video is paused at the requested position")
check(reorder(Array(before.reversed())), "Sort a live mpv playlist using production move planning")
let pausedEvents = events(for: 0.1)
let after = snapshot()!
check(after.map(\.entryID) == before.reversed().map(\.entryID), "Real libmpv order matches the desired permutation")
check(after.first(where: \.isPlaying)?.entryID == currentID, "The same decoder entry remains playing after sorting")
check(after.last?.entryID == currentID, "The playing entry can move without being reopened")
check(abs(number("time-pos") - beforePosition) < 0.001, "Sorting preserves the exact paused playback position")
check(flag("pause"), "Sorting preserves pause")
check(number("speed") == 1.7, "Sorting preserves playback speed")
check(number("ab-loop-a") == 2 && number("ab-loop-b") == 8, "Sorting preserves both A/B loop bounds")
check(!pausedEvents.contains(MPV_EVENT_START_FILE) && !pausedEvents.contains(MPV_EVENT_END_FILE)
      && !pausedEvents.contains(MPV_EVENT_FILE_LOADED), "Paused sorting produces no decoder reload or file transition")
check(!reorder(before), "A stale pre-sort snapshot is rejected by the live core")
check(snapshot()!.map(\.entryID) == after.map(\.entryID), "Rejecting a stale sort leaves the playlist untouched")

check(mpv_set_property_string(handle, "pause", "no") >= 0, "Resume real playback")
_ = events(for: 0.2)
let runningSnapshot = snapshot()!
let runningPosition = number("time-pos")
check(reorder(Array(runningSnapshot.reversed())), "Sort while the video is actively playing")
let runningEvents = events(for: 0.1)
check(!flag("pause"), "Sorting does not pause an actively playing video")
check(number("time-pos") >= runningPosition && number("time-pos") < runningPosition + 1,
      "Playback continues forward without a jump to the beginning")
check(snapshot()!.first(where: \.isPlaying)?.entryID == currentID, "Active sorting retains the same playback entry")
check(number("ab-loop-a") == 2 && number("ab-loop-b") == 8, "Active sorting retains A/B looping")
check(!runningEvents.contains(MPV_EVENT_START_FILE) && !runningEvents.contains(MPV_EVENT_END_FILE)
      && !runningEvents.contains(MPV_EVENT_FILE_LOADED), "Active sorting does not recreate the video decoder")
print("PASS: \(checks) live libmpv playback checks")
