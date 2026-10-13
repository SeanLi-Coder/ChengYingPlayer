
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let first = directory.appendingPathComponent("red.mp4").path
let second = directory.appendingPathComponent("blue.mp4").path
for mode in ["off", "file", "playlist"] {
  let engine = LiveMPV()
  let player = NavigationPlayer(engine)
  engine.load(first, then: second)
  engine.setString("loop-file", mode == "file" ? "inf" : "no")
  engine.setString("loop-playlist", mode == "playlist" ? "inf" : "no")
  engine.command(["playlist-play-index", "1"])
  engine.until("Load the last entry for navigation probe") {
    engine.loadedPaths.last == second && engine.number("playlist-pos") == 1
  }
  engine.setString("speed", "1")
  engine.setString("pause", "no")
  engine.until("Observe playback before next") { (engine.number("time-pos") ?? 0) > 0.1 }
  let loads = engine.loadedPaths.count
  let before = engine.number("time-pos") ?? -1
  player.navigateInPlaylist(nextMedia: true)
  engine.pump(0.35)
  let path = engine.getString("path") == first ? "first" : engine.getString("path") == second ? "last" : "other"
  print("MPV_NAVIGATION mode=\(mode) path=\(path) index=\(engine.number("playlist-pos") ?? -1) pause=\(String(describing: engine.flag("pause"))) loads=\(engine.loadedPaths.count - loads) command=\(navigationReturnCodes.last ?? 99) before=\(before) after=\(engine.number("time-pos") ?? -1)")
  expect(engine.flag("pause") == true, "Production next first applies pause for mode \(mode)")
  if mode == "playlist" {
    expect(path == "first" && engine.number("playlist-pos") == 0 && engine.loadedPaths.count == loads + 1,
           "Actual playlist-repeat next wraps to the first entry")
  } else {
    expect(path == "last" && engine.number("playlist-pos") == 1 && engine.loadedPaths.count == loads,
           "Actual \(mode) next stays at the last entry")
  }
}
print("Live navigation probe: \(checks) checks")
