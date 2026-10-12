import AppKit

var passes = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
  passes += 1
}
func pasteboard(_ body: (NSPasteboard) -> Void) {
  let board = NSPasteboard.withUniqueName()
  defer { board.releaseGlobally() }
  body(board)
}
func files(_ paths: [String], on board: NSPasteboard) {
  board.clearContents()
  check(board.setPropertyList(paths, forType: .nsFilenames), "Fixture writes private file list")
}

for ext in ["cube", "3dl", "CUBE"] {
  pasteboard { board in
    let original = "/synthetic/original.\(ext)"
    files([original], on: board)
    let player = PlayerCore()
    var drag: DragInfo? = DragInfo(board)
    weak var weakDrag = drag
    check(player.openFromPasteboard(drag!), "Native LUT drag is accepted asynchronously")
    check(player.filters.isEmpty && player.messages.isEmpty && player.unsafeCommands == 0,
          "Native LUT never reaches idle MPV or success OSD before restore")
    check(player.pending.map(\.reason) == ["dropped_lut"], "Native LUT requests explicit compatibility")
    check(player.openRequests.isEmpty, "A LUT does not reopen media")
    drag = nil
    check(weakDrag == nil, "Deferred LUT action does not retain dragging info")
    files(["/synthetic/replaced.cube"], on: board)
    player.finishCompatibility()
    check(player.filters.count == 1 && player.filters[0].paramDict == ["file": original, "interp": "nearest"],
          "Deferred LUT uses the immutable original path")
    check(player.filters[0].lavfiName == "lut3d" && player.filters[0].label == "iina_quickl3d",
          "LUT filter identity is preserved")
    check(player.messages == [.addFilter("3D LUT")] && player.unsafeCommands == 0,
          "LUT reports success only after the restored compatibility route")
  }
}

for ext in ["srt", "ass", "SRT"] {
  pasteboard { board in
    let original = "/synthetic/original.\(ext)"
    files([original], on: board)
    let player = PlayerCore()
    var drag: DragInfo? = DragInfo(board)
    weak var weakDrag = drag
    check(player.openFromPasteboard(drag!), "Native subtitle drag is accepted asynchronously")
    check(player.openRequests == [[URL(fileURLWithPath: original)]], "Subtitle path first follows existing media classification")
    check(player.subtitles.isEmpty && player.unsafeCommands == 0, "Native subtitle does not reach idle MPV")
    check(player.pending.map(\.reason) == ["dropped_subtitles"], "Native subtitle requests explicit compatibility")
    drag = nil
    check(weakDrag == nil, "Deferred subtitle action does not retain dragging info")
    files(["/synthetic/replaced.ass"], on: board)
    player.finishCompatibility()
    check(player.subtitles == [URL(fileURLWithPath: original)] && player.unsafeCommands == 0,
          "Deferred subtitle uses the immutable original URL")
  }
}

pasteboard { board in
  files(["/synthetic/one.srt", "/synthetic/two.ass", "/synthetic/other.txt"], on: board)
  let player = PlayerCore()
  check(player.openFromPasteboard(DragInfo(board)), "Multiple subtitles are accepted together")
  check(player.pending.count == 1 && player.subtitles.isEmpty, "Subtitle batch makes one deferred handoff")
  player.finishCompatibility()
  check(player.subtitles.map(\.lastPathComponent) == ["one.srt", "two.ass"], "Subtitle batch preserves order and filters unsupported files")
}

for path in ["/synthetic/cancel.cube", "/synthetic/cancel.srt"] {
  pasteboard { board in
    files([path], on: board)
    let player = PlayerCore()
    check(player.openFromPasteboard(DragInfo(board)), "Cancelable drop is accepted")
    player.cancelCompatibility()
    player.finishCompatibility()
    check(player.filters.isEmpty && player.subtitles.isEmpty && player.messages.isEmpty,
          "Canceled compatibility action performs no media mutation")
  }
  pasteboard { board in
    files([path], on: board)
    var player: PlayerCore? = PlayerCore()
    weak var weakPlayer = player
    check(player!.openFromPasteboard(DragInfo(board)), "Owner lifetime fixture accepts drop")
    let callback = player!.pending[0].action
    player = nil
    check(weakPlayer == nil, "Compatibility action does not retain player")
    callback()
  }
}

pasteboard { board in
  files(["/original.cube"], on: board)
  Utility.resolvedPrefix = "/resolved"
  defer { Utility.resolvedPrefix = "" }
  let player = PlayerCore()
  check(player.openFromPasteboard(DragInfo(board)), "Resolved LUT path is accepted")
  Utility.resolvedPrefix = "/changed"
  player.finishCompatibility()
  check(player.filters.first?.paramDict["file"] == "/resolved/original.cube", "Deferred action snapshots resolved path exactly once")
}

pasteboard { board in
  files(["/synthetic/fail.cube"], on: board)
  let native = PlayerCore()
  native.filterResult = false
  check(native.openFromPasteboard(DragInfo(board)), "Deferred LUT failure still records drag acceptance only")
  native.finishCompatibility()
  check(native.filters.count == 1 && native.messages.isEmpty, "Deferred filter failure never claims success")
  let legacy = PlayerCore()
  legacy.isUsingNativePlayback = false
  legacy.filterResult = false
  check(!legacy.openFromPasteboard(DragInfo(board)), "Legacy LUT failure still returns false")
  check(legacy.pending.isEmpty && legacy.messages.isEmpty, "Legacy failure neither switches backend nor shows success")
}

pasteboard { board in
  let player = PlayerCore()
  player.isUsingNativePlayback = false
  files(["/synthetic/direct.cube"], on: board)
  check(player.openFromPasteboard(DragInfo(board)) && player.filters.count == 1, "Legacy LUT applies synchronously")
  files(["/synthetic/direct.ass"], on: board)
  check(player.openFromPasteboard(DragInfo(board)) && player.subtitles.count == 1, "Legacy subtitle applies synchronously")
  check(player.pending.isEmpty && player.unsafeCommands == 0, "Legacy path adds no compatibility handoff")
}

for result in [nil, 1, 2] as [Int?] {
  pasteboard { board in
    files(["/synthetic/video.mp4"], on: board)
    let player = PlayerCore()
    player.openResult = result
    check(player.openFromPasteboard(DragInfo(board)), "Existing successful media classification is unchanged")
    check(player.pending.isEmpty && player.subtitles.isEmpty && player.filters.isEmpty,
          "Media classification does not add a subtitle or LUT handoff")
  }
}

pasteboard { board in
  let player = PlayerCore()
  check(!player.openFromPasteboard(DragInfo(board)), "Empty pasteboard returns false")
  files([], on: board)
  check(!player.openFromPasteboard(DragInfo(board)), "Empty file list returns false")
  files(["/synthetic/unsupported.txt"], on: board)
  check(!player.openFromPasteboard(DragInfo(board)), "Unrecognized nonmedia file returns false")
  board.clearContents()
  // AppKit's legacy filename converter itself throws for a scalar string. An
  // empty dictionary is accepted by that converter but still fails [String].
  check(board.setPropertyList([String: String](), forType: .nsFilenames), "Malformed file fixture is written")
  check(!player.openFromPasteboard(DragInfo(board)), "Malformed file list returns false")
  board.clearContents()
  check(board.setPropertyList([], forType: .nsURL), "Empty URL fixture is written")
  check(!player.openFromPasteboard(DragInfo(board)), "Empty URL list returns false rather than trapping")
  board.clearContents()
  check(board.setString("unsupported text", forType: .string), "Unsupported string fixture is written")
  check(!player.openFromPasteboard(DragInfo(board)), "Unsupported string returns false")
  check(player.pending.isEmpty && player.filters.isEmpty && player.subtitles.isEmpty,
        "Invalid drags never mutate media or initiate compatibility")
}
print("PASS: Native drop routing (\(passes) checks; private pasteboards only)")
