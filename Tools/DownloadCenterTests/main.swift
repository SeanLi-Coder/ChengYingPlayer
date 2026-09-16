import Cocoa
import WebKit

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
setbuf(stdout, nil)
var checks = 0
func pumpEvents(for interval: TimeInterval = 0.01) {
  _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(interval))
  while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
    NSApp.sendEvent(event)
  }
  NSApp.updateWindows()
}
func check(_ condition: @autoclosure () -> Bool, _ description: String) {
  guard condition() else { fatalError("FAIL: \(description)") }
  checks += 1
  print("PASS: \(description)")
}
func wait(_ description: String, timeout: TimeInterval = 10, until condition: () -> Bool) {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition() && Date() < deadline {
    pumpEvents()
  }
  check(condition(), description)
}
func readyData(_ edits: [String: Any] = [:]) throws -> Data {
  var value: [String: Any] = ["type": "ready", "protocol_version": 1,
                            "url": "http://127.0.0.1:34567/", "token": String(repeating: "a", count: 48), "pid": 1234]
  value.merge(edits) { _, new in new }
  return try JSONSerialization.data(withJSONObject: value)
}
let session = try DownloadCenterSession(data: readyData())
check(session.url.port == 34567 && session.pid == 1234, "The actual session decoder accepts a complete loopback handshake")
for invalid in ["https://127.0.0.1:34567/", "http://localhost:34567/", "http://127.0.0.2:34567/",
                "http://user:pass@127.0.0.1:34567/", "http://127.0.0.1:34567/?secret=a", "http://127.0.0.1:34567/#a",
                "http://127.0.0.1:34567/api/", "http://127.0.0.1/", "http://127.0.0.1:0/"] {
  check((try? DownloadCenterSession(data: readyData(["url": invalid]))) == nil, "Invalid startup origin is rejected: \(invalid)")
}
for edits: [String: Any] in [["protocol_version": 2], ["pid": 0], ["token": "short"], ["token": String(repeating: "a", count: 40) + ";"], ["type": "status"]] {
  check((try? DownloadCenterSession(data: readyData(edits))) == nil, "Incomplete or unsafe handshake fields are rejected")
}
check(session.contains(URL(string: "http://127.0.0.1:34567/")!) && !session.contains(URL(string: "http://127.0.0.1:34568/")!),
      "The native origin policy requires the exact helper port")
check(!session.acceptsOrigin(scheme: "http", host: "127.0.0.1", port: 34567, isMainFrame: false),
      "Subframes cannot invoke the native bridge")
check(session.cookie?.isHTTPOnly == true && session.cookie?.isSessionOnly == true &&
      session.cookie?.sameSitePolicy == .sameSiteStrict,
      "The real Foundation cookie is HttpOnly, session-only, and SameSite Strict")
check(DownloadCenterCommand(message: ["action": "chooseDirectory"]) != nil, "The directory command has an explicit narrow shape")
check(DownloadCenterCommand(message: ["action": "play", "jobID": "job", "itemID": "item", "index": 0]) != nil,
      "The output command accepts identifiers rather than a filesystem path")
for message: [String: Any] in [
  ["action": "chooseDirectory", "path": "/tmp/unsafe"],
  ["action": "play", "path": "/tmp/unsafe"],
  ["action": "play", "jobID": "job", "itemID": "item", "index": true],
  ["action": "play", "jobID": "job", "itemID": "item", "index": -1],
  ["action": "play", "jobID": "job", "itemID": "item", "index": 0.5],
  ["action": "shell", "jobID": "job", "itemID": "item", "index": 0],
  ["action": "reveal", "jobID": "job\n", "itemID": "item", "index": 0],
] {
  check(DownloadCenterCommand(message: message) == nil, "Unexpected bridge fields, commands, and index types fail closed")
}

let helper = URL(fileURLWithPath: CommandLine.arguments[1])
let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).resolvingSymlinksInPath()
let media = root.appendingPathComponent("fixture.mp4")
let image = root.appendingPathComponent("fixture.webp")
let executable = root.appendingPathComponent("fixture.command")
try Data("test media".utf8).write(to: media)
try Data("test image".utf8).write(to: image)
try Data("test executable".utf8).write(to: executable)
let videoOutput = DownloadCenterOutput(path: media.path, media_type: "video")
check((try? videoOutput.validatedURL(forPlayback: true)) == media, "Authenticated regular video outputs can be played")
check((try? DownloadCenterOutput(path: image.path, media_type: "image").validatedURL(forPlayback: true)) == nil,
      "Image output is not dispatched to the video player")
check((try? DownloadCenterOutput(path: executable.path, media_type: "video").validatedURL(forPlayback: true)) == nil,
      "An executable disguised as video cannot be launched")
check((try? DownloadCenterOutput(path: image.path, media_type: "image").validatedURL(forPlayback: false)) == image,
      "A saved image can still be revealed in Finder")
let link = root.appendingPathComponent("linked.mp4")
try? FileManager.default.removeItem(at: link)
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: media)
check((try? DownloadCenterOutput(path: link.path, media_type: "video").validatedURL(forPlayback: true)) == nil,
      "A post-validation symbolic-link substitution is rejected")

let locations = DownloadCenterService.Locations(helper: helper, ffmpeg: URL(fileURLWithPath: "/usr/bin/true"),
                                                ffprobe: URL(fileURLWithPath: "/usr/bin/true"),
                                                data: root.appendingPathComponent("data"), downloads: root.appendingPathComponent("downloads"))
setenv("CHENGYING_TEST_OUTPUT", media.path, 1)
if DownloadCenterService.supportsRuntime {
  for mode in ["bad_origin", "wrong_pid", "oversized", "already_running", "startup_failed", "timeout"] {
    setenv("CHENGYING_TEST_MODE", mode, 1)
    let failed = DownloadCenterService(locations: { locations }, startupTimeoutInterval: mode == "timeout" ? 0.3 : 10)
    failed.start()
    wait("The actual subprocess transport rejects \(mode)") {
      if case .failed = failed.state { return true }; return false
    }
    if case .failed(let error) = failed.state {
      check(!error.localizedDescription.contains("Do not expose"), "Raw helper errors are never displayed")
      if mode == "already_running" {
        check(error == .alreadyRunning, "An occupied data directory has its own actionable startup error")
      }
    }
    failed.shutdown()
  }
  setenv("CHENGYING_TEST_MODE", "ready", 1)
  let service = DownloadCenterService(locations: { locations })
  service.start()
  wait("The actual helper transport reaches ready state") {
    if case .ready = service.state { return true }; return false
  }
  guard case .ready(let liveSession) = service.state else { fatalError("Expected ready session") }
  var resolved: DownloadCenterOutput?
  service.resolveOutput(jobID: "job", itemID: "item", index: 0) { result in resolved = try? result.get() }
  wait("Authenticated native output lookup succeeds against a real loopback server") { resolved != nil }
  check(resolved?.path == media.path, "Only backend-resolved output paths reach native code")
  for jobID in ["redirect", "oversized_output", "missing"] {
    var requestFailed = false
    service.resolveOutput(jobID: jobID, itemID: "item", index: 0) { result in
      if case .failure = result { requestFailed = true }
    }
    wait("Authenticated native HTTP rejects \(jobID) without exposing credentials") { requestFailed }
  }

  let controller = DownloadCenterWindowController(service: service)
  _ = controller.window
  controller.window?.setFrameOrigin(NSPoint(x: -5000, y: -5000))
  controller.showWindow(nil)
  wait("The actual WKWebView loads its authenticated page") {
    controller.webView.url == liveSession.url && !controller.webView.isLoading
  }
  func javascript(_ script: String) -> Any? {
    var finished = false
    var returned: Any?
    var failure: Error?
    controller.webView.evaluateJavaScript(script) { value, error in returned = value; failure = error; finished = true }
    wait("WebKit JavaScript evaluation completes") { finished }
    check(failure == nil, "The actual WebKit page runs the requested script")
    return returned
  }
  check(javascript("document.getElementById('result').textContent") as? String == "loaded", "Authentication is applied before the page's first navigation")
  check(javascript("document.cookie") as? String == "", "HttpOnly authentication is not readable by page JavaScript")
  check(!controller.webView.configuration.websiteDataStore.isPersistent, "The embedded browser uses an isolated nonpersistent data store")
  var cookies: [HTTPCookie] = []
  var loadedCookies = false
  controller.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies = $0; loadedCookies = true }
  wait("The actual WebKit cookie store can be inspected by native tests") { loadedCookies }
  check(cookies.count == 1 && cookies[0].isHTTPOnly && cookies[0].sameSitePolicy == .sameSiteStrict,
        "WebKit preserves the restricted session cookie flags")

  var confirmationFinished = false
  controller.webView.evaluateJavaScript("cancelTask()") { _, _ in confirmationFinished = true }
  wait("The production WKUIDelegate presents the cancel confirmation sheet") { controller.window?.attachedSheet != nil }
  controller.window?.endSheet(controller.window!.attachedSheet!, returnCode: .alertFirstButtonReturn)
  wait("The JavaScript confirmation receives its native answer") { confirmationFinished }
  check(javascript("document.getElementById('result').textContent") as? String == "yes", "Confirming the native sheet does not silently cancel the web action")
  _ = javascript("playResult()")
  wait("The native bridge opens only the authenticated saved video") { PlayerCore.activeOrNew.opened == [media] }

  _ = javascript("location.href = 'https://example.invalid/'; undefined")
  _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
  check(controller.webView.url == liveSession.url, "External navigation is blocked without leaving the downloader page")
  confirmationFinished = false
  controller.webView.evaluateJavaScript("cancelTask()") { _, _ in confirmationFinished = true }
  wait("A second confirmation can be presented") { controller.window?.attachedSheet != nil }
  controller.close()
  wait("Closing the window resolves its pending JavaScript confirmation") { confirmationFinished }
  check(service.isRunning, "Closing the native window does not stop ongoing downloads")
  service.shutdown()
  check(!service.isRunning, "Application-owned shutdown closes the helper session")
  wait("EOF shutdown stops the exact owned helper process", timeout: 8) { kill(liveSession.pid, 0) != 0 && errno == ESRCH }

  setenv("CHENGYING_TEST_MODE", "frontend", 1)
  let fullService = DownloadCenterService(locations: { locations })
  let fullController = DownloadCenterWindowController(service: fullService)
  NSApp.setActivationPolicy(.accessory)
  NSApp.finishLaunching()
  NSApp.activate(ignoringOtherApps: true)
  // The preserved frontend intentionally pauses polling when its document is hidden.
  // Keep this synthetic page visible so WebKit exercises its real visibility lifecycle.
  fullController.window?.setFrameOrigin(NSPoint(x: 40, y: 40))
  fullController.showWindow(nil)
  fullController.window?.orderFrontRegardless()
  wait("The preserved frontend loads in the actual native WKWebView") {
    fullController.webView.url != nil && !fullController.webView.isLoading
  }
  func fullPageValue(_ script: String) -> Any? {
    var done = false
    var value: Any?
    var failure: Error?
    fullController.webView.evaluateJavaScript(script) { result, error in value = result; failure = error; done = true }
    let deadline = Date().addingTimeInterval(5)
    while !done && Date() < deadline { pumpEvents() }
    guard done && failure == nil else { fatalError("The preserved frontend did not evaluate its test expression") }
    return value
  }
  let decorationDeadline = Date().addingTimeInterval(8)
  var buttonCount = 0
  repeat {
    buttonCount = (fullPageValue("document.querySelectorAll('.desktop-output-actions button').length") as? NSNumber)?.intValue ?? 0
    if buttonCount >= 3 { break }
    pumpEvents(for: 0.1)
  } while Date() < decorationDeadline
  if buttonCount != 3 {
    print("NATIVE DIAGNOSTIC: window=\(String(describing: fullController.window?.frame)), visible=\(String(describing: fullController.window?.isVisible)), occlusion=\(String(describing: fullController.window?.occlusionState)), web=\(fullController.webView.frame)")
    print("FRONTEND DIAGNOSTIC: \(fullPageValue("JSON.stringify({hidden:document.hidden,errors:window.fixtureErrors,text:document.body.innerText,resources:performance.getEntriesByType('resource').map(e=>e.name)})") ?? "nil")")
  }
  check(buttonCount == 3, "Real desktop.js decorates preserved video and image output rows after API and SSE updates")
  check(fullPageValue("document.querySelectorAll('.desktop-folder-button').length") as? Int == 1,
        "The real directory chooser affordance is inserted beside the preserved settings form")
  check(fullPageValue("document.body.classList.contains('version-blocked')") as? Bool == false,
        "Embedding preserves the original frontend's build-identity gate")
  check(fullPageValue("performance.getEntriesByType('resource').some(e => new URL(e.name).pathname === '/api/health')") as? Bool == true,
        "The visible preserved frontend performs its actual backend identity handshake")
  check(fullPageValue("document.querySelector('#download-dir').value") as? String == "/tmp/fixture/downloads",
        "The preserved frontend loads its actual configuration after identity verification")
  check(fullPageValue("window.fixtureErrors.length") as? Int == 0,
        "The preserved frontend and desktop adapter run without JavaScript errors")
  check(fullPageValue("document.querySelectorAll('.download-item').length") as? Int == 2,
        "The preserved frontend renders both completed media items")
  check(fullPageValue("document.querySelectorAll('.download-item')[1].querySelector('.desktop-output-actions').textContent") as? String == "在 Finder 中显示",
        "An image output gets Finder reveal without a misleading play button")
  _ = fullPageValue("window.chengyingDownloadCenter.setDirectory('/tmp/Fixture folder'); undefined")
  check(fullPageValue("document.querySelector('#download-dir').value") as? String == "/tmp/Fixture folder",
        "The real native directory setter updates the original settings input without auto-saving")
  _ = fullPageValue("document.querySelectorAll('.item-files summary').forEach(summary => summary.click()); undefined")
  check(fullPageValue("document.querySelectorAll('.item-files[open]').length") as? Int == 2,
        "The preserved saved-file disclosure controls expose both native output actions")
  PlayerCore.activeOrNew.opened = []
  _ = fullPageValue("document.querySelector('.desktop-output-actions button').click(); undefined")
  wait("Clicking the real injected play button resolves output through the native authenticated API") {
    PlayerCore.activeOrNew.opened == [media]
  }
  if let captureDirectory = ProcessInfo.processInfo.environment["CHENGYING_CAPTURE_DIR"] {
    let directory = URL(fileURLWithPath: captureDirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let language = Bundle.main.preferredLocalizations.first ?? "en"
    for section in ["overview", "outputs"] {
      _ = fullPageValue(section == "overview" ? "window.scrollTo(0, 0); undefined" : "document.querySelectorAll('.item-files').forEach(files => { if (!files.open) files.querySelector('summary').click(); }); document.querySelector('#items-list').scrollIntoView(); undefined")
      pumpEvents(for: 0.2)
      var captured: NSImage?
      var complete = false
      fullController.webView.takeSnapshot(with: nil) { image, _ in captured = image; complete = true }
      wait("WebKit captures the actual preserved frontend \(section) viewport") { complete }
      guard let tiff = captured?.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("The preserved frontend snapshot could not be encoded")
      }
      try png.write(to: directory.appendingPathComponent("download-center-\(language)-\(section).png"))
    }
  }
  fullController.close()
  fullService.shutdown()
} else {
  let unsupported = DownloadCenterService(locations: { locations })
  unsupported.start()
  if case .failed(let error) = unsupported.state {
    check(error == .unsupportedSystem, "Older macOS keeps a clear download-only compatibility guard")
  } else { fatalError("The old-system compatibility guard did not run") }
}
print("Download center checks passed: \(checks)")
