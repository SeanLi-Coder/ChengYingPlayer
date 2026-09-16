import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  precondition(condition(), "FAIL: \(message)")
  checks += 1
}
func drain(until condition: () -> Bool) {
  let deadline = Date().addingTimeInterval(5)
  while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
  check(condition(), "Asynchronous work completes within the test deadline")
}
func drainQueue(_ player: ThumbnailPlayerUnderTest) {
  var completed = false
  player.thumbnailQueue.async { DispatchQueue.main.async { completed = true } }
  drain { completed }
}
func awaitSignal(_ signal: DispatchSemaphore) {
  check(signal.wait(timeout: .now() + 5) == .success, "The real serial queue reaches its controlled boundary")
}
func markers(_ player: ThumbnailPlayerUnderTest) -> [Int] { player.info.thumbnails.map(\.marker) }

ThumbnailCache.configure(cached: false)
let player = ThumbnailPlayerUnderTest()
let path = player.info.currentURL!.path
player.generateThumbnails()
let oldGeneration = player.thumbnailGeneration
check(player.ffmpegController.requests.count == 1 && player.ffmpegController.requests[0].generation == oldGeneration,
      "A decoder request receives the exact current generation")
player.didUpdate([FFThumbnail(1)], forFile: path, withProgress: 20, generation: oldGeneration)
check(markers(player) == [1] && player.info.thumbnailsProgress == 0.2, "Current partial thumbnails update playback state")
player.generateThumbnails()
let newGeneration = player.thumbnailGeneration
check(newGeneration != oldGeneration && markers(player).isEmpty, "Reopening the same path clears and invalidates old results")
player.didUpdate([FFThumbnail(2)], forFile: path, withProgress: 80, generation: oldGeneration)
player.didGenerate([FFThumbnail(2)], forFile: path, succeeded: true, generation: oldGeneration)
check(markers(player).isEmpty && !player.info.thumbnailsReady && player.events.count == 0,
      "Stale decoder completions for the same filename cannot mutate the new session")
player.didGenerate([FFThumbnail(3)], forFile: path + ".other", succeeded: true, generation: newGeneration)
check(markers(player).isEmpty, "A mismatched filename remains rejected even with a matching generation")
player.ffmpegController.thumbnailCount = 0
player.didUpdate(nil, forFile: path, withProgress: Int.max, generation: newGeneration)
check(player.info.thumbnailsProgress == 1, "Progress stays finite and bounded for an invalid decoder count")
player.didUpdate(nil, forFile: path, withProgress: -1, generation: newGeneration)
check(player.info.thumbnailsProgress == 0, "Negative progress cannot escape the UI range")
for state: PlayerState in [.stopping, .idle, .shuttingDown, .shutDown] {
  player.info.state = state
  player.didUpdate([FFThumbnail(4)], forFile: path, withProgress: 100, generation: newGeneration)
  player.didGenerate([FFThumbnail(4)], forFile: path, succeeded: true, generation: newGeneration)
  check(markers(player).isEmpty && !player.info.thumbnailsReady, "Inactive player ignores late decoder notifications")
}
drainQueue(player)
check(ThumbnailCache.snapshot().isEmpty, "Rejected callbacks never write a cache")

// A disk read may already be running when the same URL is reopened.
let entered = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
ThumbnailCache.configure(cached: true) {
  entered.signal()
  precondition(release.wait(timeout: .now() + 5) == .success)
  return [FFThumbnail(10)]
}
let cachedPlayer = ThumbnailPlayerUnderTest()
cachedPlayer.generateThumbnails()
awaitSignal(entered)
cachedPlayer.invalidateThumbnails()
cachedPlayer.info.thumbnails = [FFThumbnail(11)]
release.signal()
drainQueue(cachedPlayer)
check(markers(cachedPlayer) == [11] && !cachedPlayer.info.thumbnailsReady,
      "A slow cache read cannot overwrite a newer same-file session")

ThumbnailCache.configure(cached: true) { [FFThumbnail(12)] }
cachedPlayer.generateThumbnails()
drain { cachedPlayer.info.thumbnailsReady }
check(markers(cachedPlayer) == [12] && cachedPlayer.ffmpegController.requests.isEmpty,
      "A valid cache is accepted on the main thread without decoding again")
drainQueue(cachedPlayer)

ThumbnailCache.configure(cached: true)
cachedPlayer.generateThumbnails()
drain { cachedPlayer.ffmpegController.requests.count == 1 }
check(cachedPlayer.ffmpegController.requests[0].generation == cachedPlayer.thumbnailGeneration,
      "A corrupt cache falls back to decoding under the same request generation")
drainQueue(cachedPlayer)

// Block a queued write, change the live player, then inspect the immutable snapshot.
ThumbnailCache.configure(cached: false)
let writer = ThumbnailPlayerUnderTest()
writer.generateThumbnails()
let writeEntered = DispatchSemaphore(value: 0)
let writeRelease = DispatchSemaphore(value: 0)
writer.thumbnailQueue.async {
  writeEntered.signal()
  precondition(writeRelease.wait(timeout: .now() + 5) == .success)
}
awaitSignal(writeEntered)
let originalURL = writer.info.currentURL!
writer.didGenerate([FFThumbnail(20)], forFile: originalURL.path, succeeded: true, generation: writer.thumbnailGeneration)
check(writer.info.thumbnailsReady && writer.events.count == 1, "A completed current request updates the UI exactly once")
writer.info.currentURL = URL(fileURLWithPath: "/nonexistent-chengying-thumbnail-tests/next.mp4")
writer.info.mpvMd5 = "next-cache"
writer.invalidateThumbnails()
writer.info.thumbnails = [FFThumbnail(21)]
writeRelease.signal()
drainQueue(writer)
let writes = ThumbnailCache.snapshot()
check(writes.count == 1 && writes[0].markers == [20] && writes[0].name == "first-cache" && writes[0].url == originalURL,
      "Deferred cache writes cannot mix the previous filename with the next video's images or metadata")

let disabled = ThumbnailPlayerUnderTest()
Preference.enabled = false
disabled.generateThumbnails()
check(disabled.ffmpegController.requests.isEmpty && disabled.ffmpegController.cancellations == 1,
      "Disabling previews still cancels and invalidates existing work")
Preference.enabled = true
disabled.info.isNetworkResource = true
disabled.generateThumbnails()
check(disabled.ffmpegController.requests.isEmpty, "Network sources do not start thumbnail decoding")
disabled.info.isNetworkResource = false
disabled.info.currentURL = nil
disabled.generateThumbnails()
check(disabled.ffmpegController.requests.isEmpty, "A missing source is safe")
disabled.info.currentURL = originalURL
Preference.width = Int.max
disabled.generateThumbnails()
check(disabled.ffmpegController.requests.last?.width == Int32.max, "An oversized legacy width cannot trap during Swift conversion")
Preference.width = 240
disabled.invalidateThumbnails()
check(disabled.info.thumbnails.isEmpty && !disabled.info.thumbnailsReady && disabled.info.thumbnailsProgress == 0,
      "Invalidation releases retained previews and resets UI state")
check(disabled.touchBarSupport.touchBarPlaySlider!.resets == 5, "Invalidation clears cached Touch Bar images immediately")
print("Thumbnail lifecycle checks passed: \(checks)")
