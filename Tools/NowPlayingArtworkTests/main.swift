import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  checks += 1
  if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func settled(_ manager: NowPlayingInfoManager) {
  let end = Date().addingTimeInterval(4)
  while manager.artworkUpdateInProgress && Date() < end {
    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
  }
  check(!manager.artworkUpdateInProgress, "Artwork update completes within the bound")
}
func update(_ manager: NowPlayingInfoManager) {
  manager.updateArtwork(PlayerCore.lastActive, manager.currentURL, [])
  settled(manager)
}

// Hold the real artwork worker across a main-thread media replacement. The
// queue fence makes this semantic regression deterministic without a data race.
do {
  let manager = NowPlayingInfoManager()
  let oldTicket = manager.artworkTicket
  let gate = WorkerGate()
  manager.gate = gate
  manager.updateArtwork(PlayerCore.lastActive, manager.currentURL, [])
  check(gate.entered.wait(timeout: .now() + 3) == .success, "Old worker reaches the controlled boundary")
  manager.discardArtwork(manager.currentURL)
  manager.currentURL = URL(fileURLWithPath: "/synthetic-next.mp4")
  manager.updateArtwork(PlayerCore.lastActive, manager.currentURL, [])
  check(manager.artworkUpdatePending, "Replacement update remains pending until old work completes")
  manager.gate = nil
  gate.release.signal()
  manager.artworkQueue.sync {}
  check(manager.artworkQLGenerationRetries == 0, "Stale worker cannot consume the next media retry budget")
  check(manager.requests.isEmpty, "Stale worker cannot request a Quick Look thumbnail")
  settled(manager)
  check(manager.pendingUpdates == 1 && manager.requests.count == 1,
        "Stale completion starts exactly one pending current-media request")
  check(manager.requests.allSatisfy { $0.ticket != oldTicket && $0.onMain },
        "Only current tickets reserve attempts on the main thread")
  update(manager)
  update(manager)
  update(manager)
  check(manager.requests.count == 3 && manager.artworkQLGenerationRetries == 3,
        "Replacement retains its complete three-attempt budget")
  check(manager.oscRequests == 4, "Failed and exhausted Quick Look requests retain OSC fallback")
}
do {
  let manager = NowPlayingInfoManager()
  for _ in 0..<20 { update(manager) }
  check(manager.requests.count == 3 && manager.artworkQLGenerationRetries == 3,
        "Repeated refresh cannot grow the budget or exceed three Quick Look attempts")
  check(manager.requests.allSatisfy { $0.onMain }, "Every Quick Look reservation is main-thread owned")
  manager.discardArtwork(manager.currentURL)
  check(manager.artworkQLGenerationRetries == 0 && manager.artworkKind == .none,
        "Discard resets retry budget and selected artwork")
  update(manager)
  check(manager.requests.count == 4 && manager.artworkQLGenerationRetries == 1,
        "New media receives a fresh retry budget")
}
do {
  let manager = NowPlayingInfoManager()
  manager.coverAvailable = true
  update(manager)
  check(manager.artworkKind == .frontCover && manager.requests.isEmpty && manager.oscRequests == 0,
        "Front cover remains preferred over Quick Look and OSC")
  check(manager.artworkQLGenerationRetries == 0, "Cover lookup does not consume Quick Look budget")
}
do {
  let manager = NowPlayingInfoManager()
  manager.quickLookSucceeds = true
  update(manager)
  update(manager)
  check(manager.artworkKind == .qlThumbnail && manager.requests.count == 1 && manager.oscRequests == 0,
        "Existing Quick Look artwork skips redundant attempts")
  manager.coverAvailable = true
  update(manager)
  check(manager.artworkKind == .frontCover && manager.requests.count == 1,
        "A later front cover still replaces an existing Quick Look thumbnail")
}
do {
  let manager = NowPlayingInfoManager()
  PlayerCore.lastActive.info.isNetworkResource = true
  update(manager)
  check(manager.requests.isEmpty && manager.oscRequests == 0 && manager.artworkQLGenerationRetries == 0,
        "Network sources never request Quick Look or OSC fallback")
  manager.coverAvailable = true
  update(manager)
  check(manager.artworkKind == .frontCover, "Network sources retain embedded cover lookup")
  PlayerCore.lastActive.info.isNetworkResource = false
}
// Exercise main-thread resets concurrently with the real serial worker queue.
// All external boundary state accessed by both queues is explicitly atomic.
do {
  let manager = NowPlayingInfoManager()
  for _ in 0..<1000 {
    manager.discardArtwork(manager.currentURL)
    manager.updateArtwork(PlayerCore.lastActive, manager.currentURL, [])
    if manager.artworkTicket % 25 == 0 {
      RunLoop.main.run(until: Date().addingTimeInterval(0.001))
    }
  }
  settled(manager)
  check(manager.artworkQLGenerationRetries <= 3, "Rapid replacement retains the bounded current-media budget")
  check(manager.requests.allSatisfy { $0.onMain }, "Stress requests remain main-thread owned")
  let finalTicket = manager.artworkTicket
  check(manager.requests.last?.ticket == finalTicket, "The final media receives its pending artwork update")
}
print("PASS: \(checks) artwork coordination checks")
