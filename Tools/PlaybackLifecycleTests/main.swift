import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
}
func drain(until condition: () -> Bool) {
  let deadline = Date().addingTimeInterval(5)
  while !condition(), Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.002))
  }
  check(condition(), "Main-queue completion reaches the expected state")
}

func lifecycleChecks() {
  for shuttingDown in [false, true] {
    let player = PlayerUnderTest()
    let firstEntered = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let secondEntered = DispatchSemaphore(value: 0)
    let releaseSecond = DispatchSemaphore(value: 0)
    player.taskBody = { ticket in
      if ticket == 1 {
        firstEntered.signal()
        precondition(releaseFirst.wait(timeout: .now() + 5) == .success)
      } else {
        secondEntered.signal()
        precondition(releaseSecond.wait(timeout: .now() + 5) == .success)
      }
    }
    player.fileStarted(path: "/nonexistent-chengying-test/first.mp4")
    check(firstEntered.wait(timeout: .now() + 5) == .success, "First real background task starts")
    player.fileStarted(path: "/nonexistent-chengying-test/second.mp4")
    releaseFirst.signal()
    check(secondEntered.wait(timeout: .now() + 5) == .success, "Second task runs before the old main-queue completion")
    drain { player.finishedTasks == 1 }
    check(player.backgroundTaskInUse, "An older file completion cannot clear a newer task's ownership")
    check(player.videoToolsMediaGeneration == 2, "File-generation and loop reset behavior is retained")
    if shuttingDown {
      player.info.state = .idle
      player.shutdown()
      check(player.mpv.quit == 0, "Shutdown waits for all pending matcher tasks")
    } else {
      player.stop()
      check(player.mpv.stopped == 0, "Stop waits for all pending matcher tasks")
      check(player.mainWindow.videoView.stops == 0, "The display link remains available until all background tasks finish")
    }
    releaseSecond.signal()
    drain { player.finishedTasks == 2 }
    check(!player.backgroundTaskInUse, "Ownership is released after the last completion")
    check(shuttingDown ? player.mpv.quit == 1 : player.mpv.stopped == 1,
          "The deferred stop or quit command runs exactly once")
  }

  let stopped = PlayerUnderTest()
  stopped.info.state = .shutDown
  stopped.fileStarted(path: "/nonexistent-chengying-test/late.mp4")
  stopped.stop()
  check(!stopped.backgroundTaskInUse && stopped.mpv.stopped == 0,
        "Late file-start and stop callbacks remain harmless after shutdown")
}

func filterReadFailureChecks() {
  let controller = FilterControllerUnderTest()
  controller.mpv!.mode = .unavailable
  check(controller.getFilters("vf").isEmpty, "An unavailable filter property does not force-unwrap nil")
  check(!controller.removeFilter("vf", 0), "An unavailable filter list fails safely")
  controller.mpv = nil
  check(controller.getFilters("vf").isEmpty && !controller.removeFilter("vf", 0),
        "An already destroyed core receives no filter API calls")
}

func filterNegativeChecks() {
  let controller = FilterControllerUnderTest()
  check(!controller.removeFilter("vf", -1), "A negative filter index cannot overrun the new node array")
  check(controller.mpv!.writes == 0 && controller.mpv!.values == [11, 22, 33],
        "Rejected removal leaves the filter list unchanged")
}

func filterWriteFailureChecks() {
  let controller = FilterControllerUnderTest()
  controller.mpv!.writeSucceeds = false
  check(!controller.removeFilter("vf", 1), "An mpv write failure is reported to the caller")
  check(controller.mpv!.values == [11, 22, 33], "A failed removal does not pretend to change the list")
}

func filterChecks() {
  filterReadFailureChecks()
  filterNegativeChecks()
  filterWriteFailureChecks()
  for mode: FilterMPV.ReadMode in [.wrongFormat, .missingList, .missingValues] {
    let controller = FilterControllerUnderTest()
    controller.mpv!.mode = mode
    let releases = FilterMPV.releases
    check(!controller.removeFilter("af", 0), "Malformed filter node boundaries are rejected")
    check(FilterMPV.releases == releases + 1, "Early removal failure frees the returned node")
    check(controller.mpv!.writes == 0, "Malformed nodes never reach the write API")
  }
  for index in [0, 1, 2] {
    let controller = FilterControllerUnderTest()
    let expected = [Int64(11), 22, 33].enumerated().filter { $0.offset != index }.map(\.element)
    check(controller.removeFilter("vf", index), "A valid filter removal succeeds")
    check(controller.mpv!.values == expected, "Only the requested filter is removed in order")
  }
  let controller = FilterControllerUnderTest()
  controller.mpv!.values = [11]
  check(controller.removeFilter("af", 0) && controller.mpv!.values.isEmpty, "The last filter can be removed")
  check(!controller.removeFilter("af", 0), "An empty filter list is safely rejected")
  controller.mpv!.values = [11, 22, 33]
  check(!controller.removeFilter("vf", 3) && !controller.removeFilter("vf", Int.max),
        "Upper-bound and oversized indexes are rejected")
  MPVNode.parsedValue = [["name": "hflip", "label": "flip"] as [String: Any?], ["label": "missing-name"]]
  let releases = FilterMPV.releases
  check(controller.getFilters("vf").map(\.name) == ["hflip"], "A nameless filter cannot crash filter enumeration")
  check(FilterMPV.releases == releases + 1, "Successful enumeration frees the returned node")
  MPVNode.parsedValue = nil
  let nilReleases = FilterMPV.releases
  check(controller.getFilters("vf").isEmpty, "A nil parsed node is safe")
  check(FilterMPV.releases == nilReleases + 1, "Nil enumeration frees the returned node")
  MPVNode.throwsOnParse = true
  let errorReleases = FilterMPV.releases
  check(controller.getFilters("vf").isEmpty, "A parse failure is safe")
  check(FilterMPV.releases == errorReleases + 1, "Throwing enumeration frees the returned node")
  MPVNode.throwsOnParse = false
}

switch CommandLine.arguments.dropFirst().first ?? "all" {
case "lifecycle": lifecycleChecks()
case "filter-read-failure": filterReadFailureChecks()
case "filter-negative": filterNegativeChecks()
case "filter-write-failure": filterWriteFailureChecks()
case "all": lifecycleChecks(); filterChecks()
default: fatalError("Unknown playback regression test group")
}
print("Playback lifecycle and filter checks passed: \(checks)")
