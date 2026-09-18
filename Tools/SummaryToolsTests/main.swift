import Cocoa

final class FixtureWindowBackground: NSView {
  // View-only snapshots omit the window-server background underneath a plain content view.
  override func draw(_ dirtyRect: NSRect) {
    (window?.backgroundColor ?? .windowBackgroundColor).setFill()
    dirtyRect.fill()
  }
}

NSApplication.shared.setActivationPolicy(.prohibited)
setbuf(stdout, nil)
var checks = 0
func check(_ value: @autoclosure () throws -> Bool, _ message: String) {
  guard (try? value()) == true else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}
func rejects(_ message: String, _ operation: () throws -> Void) {
  do { try operation(); fatalError("FAIL: \(message)") }
  catch { check(true, message) }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("summary-native-\(UUID().uuidString)", isDirectory: true)
  .resolvingSymlinksInPath()
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let hardware = SubtitleToolsHardware(supportsRuntime: true, physicalMemory: 128 * 1024 * 1024 * 1024)
let transport = SubtitleTransportDouble()
let service = SubtitleToolsService(transport: transport, hardware: hardware, dataDirectory: { root })
let url = "https://www.youtube.com/watch?v=abcdefghijk"
for (input, expected) in [
  (url + "&list=PLfixture&index=2&t=10&token=discard", url),
  ("https://youtu.be/abcdefghijk?t=9", url),
  ("http://m.youtube.com/shorts/abcdefghijk", url),
  ("https://www.bilibili.com/video/BV1234567890?p=2&token=discard", "https://www.bilibili.com/video/BV1234567890?p=2"),
  ("https://b23.tv/fixture?tracking=discard", "https://b23.tv/fixture")
] { check(try SummaryToolsSource.normalized(input).absoluteString == expected, "Single-video normalization strips unrelated query data") }
for input in ["file:///etc/passwd", "https://youtube.com.evil.test/watch?v=abcdefghijk", "https://user:secret@youtube.com/watch?v=abcdefghijk",
              "https://www.youtube.com/playlist?list=PLfixture", "https://localhost/watch?v=abcdefghijk", "https://youtu.be/short",
              "https://www.youtube.com:7890/watch?v=abcdefghijk", "https://www.youtube.com/watch?v=abcdefghijk&v=anotherone",
              "https://bilibili.com/video/BV1234567890?p=0", "https://b23.tv/../outside", "https://youtube.com/watch?v=abcdefghijk\ninvalid"] {
  rejects("Invalid, credential-bearing, and non-video sources are rejected") { _ = try SummaryToolsSource.normalized(input) }
}
service.refreshStatus()
transport.ready()
check(service.isReady && !service.summaryReady, "Existing subtitle readiness does not require the new summary model")
service.refreshStatus()
var summaryOnly = SubtitleToolsModel.allModels
for index in summaryOnly.indices {
  summaryOnly[index].ready = summaryOnly[index].id == "summarizer"
  summaryOnly[index].totalBytes = 100
  summaryOnly[index].downloadedBytes = summaryOnly[index].ready ? 100 : 0
  summaryOnly[index].storedBytes = summaryOnly[index].ready ? 120 : 0
}
transport.emitStatus(runtimeReady: true, models: summaryOnly)
check(service.summaryReady && !service.isReady, "Caption-only summaries need no verified speech or translation weights")

var copied = "", downloadCenters = 0, licenses = 0
var exportCompletion: ((URL?) -> Void)?
var deletionPrompt: SubtitleToolsModel?
var deletionCompletion: ((Bool) -> Void)?
let controller = SummaryToolsWindowController(service: service, openDownloadCenter: { downloadCenters += 1 },
  copyText: { copied = $0 }, chooseExport: { _, completion in exportCompletion = completion },
  confirmModelDeletion: { model, _, completion in deletionPrompt = model; deletionCompletion = completion },
  openModelLicense: { licenses += 1 })
let window = controller.window!
let background = FixtureWindowBackground(frame: window.contentView!.bounds)
background.autoresizingMask = [.width, .height]
window.contentView!.addSubview(background, positioned: .below, relativeTo: nil)
window.orderFront(nil)
check(transport.requests.allSatisfy { $0.command == "status" } && downloadCenters == 0 && licenses == 0,
      "Opening a window performs no unsolicited model download, browser launch, or clipboard write")
controller.downloadCenterButton.performClick(nil)
controller.licenseButton.performClick(nil)
check(downloadCenters == 1 && licenses == 1, "Website configuration and license actions use their injected boundaries")
check(!controller.resultView.isEditable && !controller.resultView.isRichText && !controller.resultView.isAutomaticLinkDetectionEnabled,
      "The result is selectable, non-executing plain Markdown, not a web view")
check(controller.modelPopup.numberOfItems == 4 && controller.modelPopup.selectedItem?.representedObject as? String == "summarizer"
        && controller.deleteModelButton.isEnabled && controller.verifyButton.isEnabled,
      "The summary model manager exposes the summarizer and all shared models with local verification and deletion")
controller.deleteModelButton.performClick(nil)
check(deletionPrompt?.id == "summarizer" && service.task == nil, "Summary model deletion first opens a model-specific confirmation")
deletionCompletion?(false)
check(!transport.requests.contains { $0.command == "delete_model" }, "Cancelling summary model deletion has no helper side effect")

func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
func snapshot(_ state: String) throws {
  let content = window.contentView!
  content.layoutSubtreeIfNeeded()
  let all = descendants(content)
  // TextKit manages these exact private rendering layers independently; all application views stay checked.
  let textKitLayers: Set<String> = ["_NSTextSelectionView", "_NSTextRenderingSurfacesGroupView", "_NSTextContentView"]
  let ambiguous = all.filter { !textKitLayers.contains(String(describing: type(of: $0))) && $0.hasAmbiguousLayout }
  check(ambiguous.isEmpty, "The \(state) native layout is unambiguous: \(ambiguous.map { String(describing: type(of: $0)) })")
  for view in all where view.identifier?.rawValue.hasPrefix("summary.") == true && view !== controller.resultView {
    let frame = view.convert(view.bounds, to: content)
    check(content.bounds.insetBy(dx: -1, dy: -1).contains(frame), "The \(state) \(view.identifier!.rawValue) stays within actual bounds")
    if let label = view as? NSTextField, label !== controller.sourceField {
      let needed = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 10_000)).height
      check(label.bounds.height + 1 >= needed, "The \(state) label does not vertically clip its declared line count")
    }
  }
  check(controller.resultView.enclosingScrollView!.contentView.bounds.height >= 100 && controller.resultView.bounds.width > 100,
        "The \(state) result retains a usable native scrolling text surface")
  guard let capture = ProcessInfo.processInfo.environment["CHENGYING_CAPTURE_DIR"] else { return }
  let language = Bundle.main.preferredLocalizations.first ?? "en"
  let directory = URL(fileURLWithPath: capture).appendingPathComponent(language)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    window.appearance = NSAppearance(named: appearance)
    content.layoutSubtreeIfNeeded()
    descendants(content).forEach { $0.needsDisplay = true }
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    window.displayIfNeeded()
    window.effectiveAppearance.performAsCurrentDrawingAppearance {
      let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
      content.cacheDisplay(in: content.bounds, to: bitmap)
      let file = directory.appendingPathComponent("summary-\(state)-\(name).png")
      try! bitmap.representation(using: .png, properties: [:])!.write(to: file)
      print("SNAPSHOT: \(file.path)")
    }
  }
}
try snapshot("idle")
window.setContentSize(window.contentMinSize)
try snapshot("minimum")
service.refreshStatus()
transport.emitStatus(runtimeReady: false, models: summaryOnly)
check(controller.modelLabel.stringValue.contains(subtitleToolsString("models.runtime_pending")) && !controller.startButton.isEnabled,
      "Verified model files remain distinct from a missing or incompatible runtime")
try snapshot("runtime-pending")
service.refreshStatus()
transport.emitStatus(runtimeReady: true, models: summaryOnly)

let barrier = UUID()
check(UpdateWorkAdmission.shared.acquire(barrier), "The update barrier starts idle")
rejects("The update barrier rejects summary preparation") { _ = try service.prepareSummaryModels() }
rejects("The update barrier rejects generation before creating a task") { _ = try service.summarize(source: url) }
UpdateWorkAdmission.shared.release(barrier)
controller.verifyButton.performClick(nil)
let verifyID = service.task!.id
check(service.task?.operation == .verify && transport.requests.last?.command == "verify",
      "The summary window's local verification action never invokes model preparation or download")
transport.emit(SubtitleToolsEvent(type: .progress, id: verifyID, operation: .verify, stage: "verify", progress: 0.4,
                                  downloadedBytes: 40, totalBytes: 100, etaSeconds: 15, etaScope: "current_file_verification"))
check(controller.countLabel.stringValue.contains(String(format: summaryToolsString("counts.eta.verify"), 15.0))
        && !controller.verifyButton.isEnabled && !controller.deleteModelButton.isEnabled,
      "Verification reports a current-file ETA and blocks model deletion across the shared service")
try snapshot("local-verification")
controller.cancelButton.performClick(nil)
transport.emit(SubtitleToolsEvent(type: .cancelled, id: verifyID, operation: .verify,
                                  runtimeReady: true, models: summaryOnly))
transport.emitStatus(runtimeReady: true, models: summaryOnly)
let prepareID = try service.prepareSummaryModels()
let prepareRequest = transport.requests.last!
check(prepareRequest.command == "prepare" && prepareRequest.purpose == "summary", "Preparation requests only the summary-specific model set")
transport.emit(SubtitleToolsEvent(type: .progress, id: prepareID, operation: .prepare, stage: "download", progress: 0.4,
                                  downloadedBytes: 400, totalBytes: 1000, bytesPerSecond: 25, etaSeconds: 24))
check(!controller.progress.isIndeterminate && controller.countLabel.stringValue.contains("25"), "Download progress and speed come from helper measurements")
try snapshot("model-download")
controller.cancelButton.performClick(nil)
check(transport.requests.last?.targetID == prepareID && service.task?.phase == .cancelling, "Pause cancels exactly the owned preparation task")
transport.emit(SubtitleToolsEvent(type: .cancelled, id: prepareID, operation: .prepare))

controller.sourceField.stringValue = url + "&list=PLfixture"
controller.startButton.performClick(nil)
let taskID = service.task!.id
let requestData = try JSONEncoder().encode(transport.requests.last!)
let requestJSON = try JSONSerialization.jsonObject(with: requestData) as! [String: Any]
check(requestJSON["command"] as? String == "summarize" && requestJSON["source_url"] as? String == url && requestJSON["input_path"] == nil,
      "The real Start action emits canonical source_url and summarize without subtitle fields")
check(service.task?.isActive == true, "Summaries use the same service task observed by automatic-update safety")
rejects("One helper cannot accept competing subtitle preparation") { _ = try service.prepareModels() }
transport.emit(SubtitleToolsEvent(type: .progress, id: taskID, operation: .summary, stage: "verify", progress: 0.75,
                                  downloadedBytes: 75, totalBytes: 100))
transport.emit(SubtitleToolsEvent(type: .progress, id: taskID, operation: .summary, stage: "summary_loading"))
check(service.task?.progress == nil && service.task?.totalBytes == 0 && controller.progress.isIndeterminate,
      "A stage with unknown progress clears the previous verification percentage and byte count")
transport.emit(SubtitleToolsEvent(type: .progress, id: taskID, operation: .summary, stage: "downloading_audio", downloadedBytes: 90, totalBytes: 100))
transport.emit(SubtitleToolsEvent(type: .progress, id: taskID, operation: .summary, stage: "recognizing"))
check(service.task?.downloadedBytes == 0 && service.task?.totalBytes == 0, "Audio-to-recognition transitions also clear download totals")
transport.emit(SubtitleToolsEvent(type: .progress, id: taskID, operation: .summary, stage: "summary_mapping", progress: 0.25,
                                  message: "Hidden reasoning must never be displayed", tokensGenerated: 42, chunkIndex: 1, chunkCount: 4, elapsedSeconds: 12))
check(controller.countLabel.stringValue.contains("42") && !controller.statusLabel.stringValue.contains("Hidden reasoning") && controller.resultView.string.isEmpty,
      "Live generation displays real counts without hidden thinking or unfinished model text")
check(controller.progress.minValue == 0 && controller.progress.maxValue == 100 && controller.progress.doubleValue == 25,
      "A one-quarter stage uses the native indicator's 0-to-100 scale")
try snapshot("generating")
var confirmations = 0
check(!SummaryToolsLifecycle.mayTerminate(task: service.task) { confirmations += 1; return false } && confirmations == 1,
      "Cancelling quit preserves the active shared AI task")
check(SummaryToolsLifecycle.mayTerminate(task: service.task) { true }, "Only explicit stop-and-quit permits active-task termination")
let beforeClose = transport.requests.filter { $0.command == "cancel" }.count
window.performClose(nil)
check(service.task?.isActive == true && transport.requests.filter { $0.command == "cancel" }.count == beforeClose,
      "Closing the summary window neither stops nor cancels its background task")
window.orderFront(nil)

let job = root.appendingPathComponent("summaries/\(taskID)", isDirectory: true)
try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
let report = job.appendingPathComponent("report.md"), transcript = job.appendingPathComponent("transcript.json")
let markdown = "# Fixture overview\n\n- [00:12] A source-grounded note.\n\n<script>not executed</script> [Link](https://example.invalid/)\n"
try markdown.write(to: report, atomically: true, encoding: .utf8)
try Data("{\"segments\":[]}".utf8).write(to: transcript)
let completed = SubtitleToolsEvent(type: .completed, id: taskID, operation: .summary,
                                  outputs: SubtitleToolsOutputs(summary: report.path, transcript: transcript.path),
                                  summaryText: markdown, title: "Fixture overview", contentSource: "captions")
check(try SummaryToolsFiles.readResult(completed, taskID: taskID, dataDirectory: root).text == markdown, "Only the fixed owned report and transcript are accepted")
var malicious = completed
malicious.outputs = SubtitleToolsOutputs(summary: root.appendingPathComponent("outside.md").path, transcript: transcript.path)
rejects("An arbitrary output path is never read") { _ = try SummaryToolsFiles.readResult(malicious, taskID: taskID, dataDirectory: root) }
malicious = completed; malicious.summaryText = "Not the report contents"
rejects("Reported text must match the bounded verified report") { _ = try SummaryToolsFiles.readResult(malicious, taskID: taskID, dataDirectory: root) }
malicious.summaryText = String(repeating: "x", count: SummaryToolsFiles.maximumSummaryBytes + 1)
rejects("Oversized inline summaries are rejected before display") { _ = try SummaryToolsFiles.readResult(malicious, taskID: taskID, dataDirectory: root) }
let savedReport = job.appendingPathComponent("saved.md")
try FileManager.default.moveItem(at: report, to: savedReport)
try FileManager.default.createSymbolicLink(at: report, withDestinationURL: savedReport)
rejects("A report symlink is never followed") { _ = try SummaryToolsFiles.readResult(completed, taskID: taskID, dataDirectory: root) }
try FileManager.default.removeItem(at: report)
try FileManager.default.linkItem(at: savedReport, to: report)
rejects("A hard-linked report cannot import another file") { _ = try SummaryToolsFiles.readResult(completed, taskID: taskID, dataDirectory: root) }
try FileManager.default.removeItem(at: report)
try FileManager.default.moveItem(at: savedReport, to: report)
let savedJob = job.deletingLastPathComponent().appendingPathComponent("saved-job")
try FileManager.default.moveItem(at: job, to: savedJob)
try FileManager.default.createSymbolicLink(at: job, withDestinationURL: savedJob)
rejects("A job-directory symlink is never followed") { _ = try SummaryToolsFiles.readResult(completed, taskID: taskID, dataDirectory: root) }
try FileManager.default.removeItem(at: job)
try FileManager.default.moveItem(at: savedJob, to: job)
transport.emit(completed)
check(service.task?.phase == .completed && controller.resultText == markdown, "A valid completion renders the verified final Markdown")
check(!controller.progress.isIndeterminate && controller.progress.maxValue == 100 && controller.progress.doubleValue == 100,
      "A completed task fills the native progress indicator")
check(controller.resultView.textStorage?.attribute(.link, at: markdown.count - 4, effectiveRange: nil) == nil,
      "Markdown links remain inert plain text")
controller.copyButton.performClick(nil)
check(copied == markdown, "Copy exports exactly the final report through an injected clipboard boundary")
controller.exportButton.performClick(nil)
check(UpdateWorkAdmission.shared.activeReasons == ["busy.subtitles"], "An export chooser holds an installation-prevention lease")
let exported = root.appendingPathComponent("export.md")
exportCompletion?(exported)
check(try String(contentsOf: exported, encoding: .utf8) == markdown && UpdateWorkAdmission.shared.activeReasons.isEmpty,
      "Export writes only the explicitly chosen fixture destination and releases its lease")
controller.exportButton.performClick(nil); exportCompletion?(nil)
check(UpdateWorkAdmission.shared.activeReasons.isEmpty, "Cancelling the export chooser also releases its lease")
try snapshot("completed")
check(SummaryToolsLifecycle.mayTerminate(task: service.task) { fatalError("Idle tasks must not prompt") }, "Completed tasks do not create a redundant quit prompt")
controller.deleteModelButton.performClick(nil)
deletionCompletion?(true)
let deleteID = service.task!.id
check(service.task?.operation == .deleteModel && transport.requests.last?.modelID == "summarizer",
      "Confirmed summary deletion sends exactly the selected allowlisted model id")
check(!controller.cancelButton.isEnabled && !controller.prepareButton.isEnabled && !controller.modelPopup.isEnabled,
      "Deleting a model disables cancellation, downloads and model selection until its terminal response")
let cancellationCount = transport.requests.filter { $0.command == "cancel" }.count
controller.cancelButton.performClick(nil)
check(transport.requests.filter { $0.command == "cancel" }.count == cancellationCount,
      "The summary Cancel control cannot interrupt a model deletion")
transport.emit(SubtitleToolsEvent(type: .progress, id: deleteID, operation: .deleteModel, stage: "delete_model", progress: 0.5))
try snapshot("deleting-model")
var summaryDeleted = summaryOnly
let summaryIndex = summaryDeleted.firstIndex { $0.id == "summarizer" }!
summaryDeleted[summaryIndex].ready = false
summaryDeleted[summaryIndex].downloadedBytes = 0
summaryDeleted[summaryIndex].storedBytes = 0
transport.emit(SubtitleToolsEvent(type: .completed, id: deleteID, operation: .deleteModel, stage: "complete",
                                  runtimeReady: true, models: summaryDeleted))
transport.emitStatus(runtimeReady: true, models: summaryDeleted)
check(!service.summaryReady && !controller.startButton.isEnabled && !controller.deleteModelButton.isEnabled
        && controller.resultText == markdown && controller.copyButton.isEnabled,
      "Deleting summary weights disables new inference without deleting or hiding an already generated report")
try snapshot("model-deleted")
summaryDeleted[0].storedBytes = 12
service.refreshStatus()
transport.emitStatus(runtimeReady: true, models: summaryDeleted)
controller.modelPopup.selectItem(at: 0)
_ = controller.modelPopup.sendAction(controller.modelPopup.action!, to: controller.modelPopup.target)
check(controller.deleteModelButton.isEnabled, "The summary manager can clean invalid-file leftovers even when downloaded bytes are zero")
controller.deleteModelButton.performClick(nil)
check(deletionPrompt?.id == "asr", "The summary manager exposes deletion for the shared speech-recognition model")
deletionCompletion?(false)
service.refreshStatus()
transport.emitStatus(runtimeReady: true, models: summaryOnly)
let errorID = try service.summarize(source: url)
transport.emit(SubtitleToolsEvent(type: .failed, id: errorID, operation: .summary,
                                  error: String(repeating: "Fixture source unavailable; check website login and network. ", count: 18)))
try snapshot("long-error")

let smallTransport = SubtitleTransportDouble()
let smallService = SubtitleToolsService(transport: smallTransport,
  hardware: SubtitleToolsHardware(supportsRuntime: true, physicalMemory: 64 * 1024 * 1024 * 1024), dataDirectory: { root })
let smallWindow = SummaryToolsWindowController(service: smallService, openDownloadCenter: {})
let smallID = try smallService.prepareSummaryModels()
smallTransport.emit(SubtitleToolsEvent(type: .progress, id: smallID, operation: .prepare, stage: "download", progress: 0.3))
check(smallWindow.statusLabel.stringValue.contains(subtitleToolsString("stage.download")), "Low-memory Macs still display real preparation stage progress")
smallTransport.emit(SubtitleToolsEvent(type: .failed, id: smallID, operation: .prepare, error: "Fixture preparation failed"))
check(smallWindow.statusLabel.stringValue.contains("Fixture preparation failed"), "Low-memory preparation failures are not hidden behind an inference warning")
rejects("Low-memory inference cannot fall back to a smaller model") { _ = try smallService.summarize(source: url) }

let cold = root.appendingPathComponent("cold", isDirectory: true)
let fixtureHelper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("FixtureHelper")
let downloaderData = cold.appendingPathComponent("DownloadCenter", isDirectory: true)
let realClient = SubtitleToolsHelperClient(locations: {
  SubtitleToolsHelperClient.Locations(helper: fixtureHelper, ffmpeg: fixtureHelper, ffprobe: fixtureHelper,
    data: cold.appendingPathComponent("SubtitleTools", isDirectory: true),
    downloader: cold.appendingPathComponent("Helpers/DownloadCenter.app/Contents/MacOS/chengying-download-center-helper"),
    downloaderData: downloaderData)
})
var coldReady = false, coldError: Error?
realClient.eventHandler = { if $0.type == .status { coldReady = true } }
realClient.failureHandler = { coldError = $0 }
try realClient.send(SubtitleToolsRequest(id: UUID().uuidString, command: "status"))
let deadline = Date().addingTimeInterval(5)
while !coldReady && coldError == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
check(coldReady && coldError == nil, "The real JSONL client cold-starts with an empty shared downloader-data directory")
check(try FileManager.default.contentsOfDirectory(atPath: downloaderData.path).isEmpty, "Cold start does not create cookies, configuration, or downloader jobs")
realClient.shutdown()
window.orderOut(nil)
smallWindow.window?.orderOut(nil)
print("SUCCESS: \(checks) native summary checks passed")
