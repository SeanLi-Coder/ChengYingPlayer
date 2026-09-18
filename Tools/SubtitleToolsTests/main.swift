import Cocoa

setbuf(stdout, nil)
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
  guard value() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}
func property<T>(_ name: String, of controller: SubtitleToolsViewController, as type: T.Type) -> T {
  guard let result = Mirror(reflecting: controller).children.first(where: { $0.label == name })?.value as? T else {
    fatalError("Missing property: \(name)")
  }
  return result
}
func action(_ control: NSControl) {
  guard let selector = control.action else { fatalError("Missing action") }
  _ = control.sendAction(selector, to: control.target)
}
let supported = SubtitleToolsHardware(supportsRuntime: true, physicalMemory: 128 * 1024 * 1024 * 1024)
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chengying-subtitle-tests-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let source = directory.appendingPathComponent("original.mp4")
try Data("Source fixture".utf8).write(to: source)
let originalBytes = try Data(contentsOf: source)
let transport = SubtitleTransportDouble()
let service = SubtitleToolsService(transport: transport, hardware: supported)
var deletionRequest: SubtitleToolsModel?
var deletionConfirmation: ((Bool) -> Void)?
let updateBarrier = UUID()
check(UpdateWorkAdmission.shared.acquire(updateBarrier), "Subtitle update fixture acquires native admission")
service.refreshStatus()
for operation in ["prepare", "subtitles", "verify", "delete_model"] {
  do {
    if operation == "prepare" { _ = try service.prepareModels() }
    else if operation == "verify" { _ = try service.verifyModels() }
    else if operation == "delete_model" { _ = try service.deleteModel(id: "asr") }
    else { _ = try service.start(inputURL: source, language: "auto", burnSubtitles: false) }
    fatalError("FAIL: Update barrier accepted subtitle work")
  } catch SubtitleToolsError.busy {
    check(service.task == nil, "Update barrier rejects subtitle work before creating a task")
  }
}
UpdateWorkAdmission.shared.release(updateBarrier)
let player = PlayerCore()
player.info.currentURL = source
let controller = SubtitleToolsViewController(player: player, service: service, confirmModelDeletion: { model, _, completion in
  deletionRequest = model
  deletionConfirmation = completion
})
let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
panel.contentViewController = controller
controller.view.frame = NSRect(x: 0, y: 0, width: 340, height: 700)
controller.view.layoutSubtreeIfNeeded()
controller.viewDidLayout()
let generate = property("generateButton", of: controller, as: NSButton.self)
let prepare = property("prepareButton", of: controller, as: NSButton.self)
let verify = property("verifyButton", of: controller, as: NSButton.self)
let cancel = property("cancelButton", of: controller, as: NSButton.self)
let burn = property("burnCheckbox", of: controller, as: NSButton.self)
let languages = property("languagePopup", of: controller, as: NSPopUpButton.self)
let tabs = property("tabs", of: controller, as: NSSegmentedControl.self)
let status = property("statusLabel", of: controller, as: NSTextField.self)
let reveal = property("revealButton", of: controller, as: NSButton.self)
check(tabs.segmentCount == 2 && tabs.label(forSegment: 1) == subtitleToolsString("tab.models"), "The native panel contains localized generation and model-management tabs")
check(burn.state == .off, "Burned-in video is disabled by default")
check(languages.numberOfItems == 6 && languages.indexOfSelectedItem == 0, "Exactly the six supported source languages are exposed with automatic detection selected")
check(!generate.isEnabled && prepare.isEnabled, "Generation waits for verified models while pre-download remains available")
check(transport.requests.last?.command == "status", "Opening the panel requests status without downloading models")

let partial = SubtitleToolsModel.fixedModels.map { model -> SubtitleToolsModel in
  var copy = model
  copy.totalBytes = 100
  copy.downloadedBytes = 50
  return copy
}
transport.emitStatus(runtimeReady: false, models: partial)
check(prepare.title == subtitleToolsString("models.resume"), "A partial download offers resume")
let automaticVerifyID = service.task!.id
check(service.task?.operation == .verify && transport.requests.last?.command == "verify" && !prepare.isEnabled,
      "The first local model status automatically starts only local verification and disables competing work")
var completeUnverified = partial
for index in completeUnverified.indices { completeUnverified[index].downloadedBytes = 100 }
transport.emit(SubtitleToolsEvent(type: .completed, id: automaticVerifyID, operation: .verify, stage: "complete",
                                  runtimeReady: false, models: completeUnverified))
transport.emitStatus(runtimeReady: false, models: completeUnverified)
service.refreshStatus()
transport.emitStatus(runtimeReady: false, models: completeUnverified)
check(prepare.title == subtitleToolsString("models.repair") && verify.isEnabled && !generate.isEnabled,
      "Complete files expose independent local verification and runtime repair without claiming readiness")
check(transport.requests.filter { $0.command == "verify" }.count == 1,
      "Repeated status responses do not start another automatic verification")
service.refreshStatus()
transport.ready()
check(service.isReady && generate.isEnabled, "Verified models and runtime enable generation")

func checkPanelWidth(_ controls: [(String, NSView)]) {
  controller.view.layoutSubtreeIfNeeded()
  controller.viewDidLayout()
  for (name, control) in controls {
    let rect = controller.view.convert(control.bounds, from: control)
    check(rect.width > 0 && rect.minX >= 0 && rect.maxX <= 340.5, "\(name) fits the 340-point native sidebar")
  }
}
func visibleLabels(in view: NSView) -> [NSTextField] {
  guard !view.isHiddenOrHasHiddenAncestor else { return [] }
  return (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(visibleLabels)
}
checkPanelWidth([("Source language", languages), ("Burn option", burn), ("Generate action", generate), ("Task status", status)])
let hardware = property("hardwareLabel", of: controller, as: NSTextField.self)
check(!hardware.isHiddenOrHasHiddenAncestor && hardware.stringValue.contains("96 GiB"),
      "The required unified-memory capacity remains visible above both tabs")
check(visibleLabels(in: controller.view).contains { $0.stringValue == subtitleToolsString("generate.external_hint") },
      "The generation page retains the lossless output and large-file explanation")
check(generate.bezelColor != nil, "The primary generation action has a distinct accent treatment")
check(!generate.isHiddenOrHasHiddenAncestor && prepare.isHiddenOrHasHiddenAncestor,
      "The generation page hides the complete model-manager hierarchy")
tabs.selectedSegment = 1; action(tabs)
let modelLabels = property("modelLabels", of: controller, as: [String: NSTextField].self)
let deleteButtons = property("modelDeleteButtons", of: controller, as: [String: NSButton].self)
checkPanelWidth(modelLabels.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value as NSView) } + [("Model preparation", prepare)])
check(generate.isHiddenOrHasHiddenAncestor && !prepare.isHiddenOrHasHiddenAncestor,
      "The model page hides the complete generation-card hierarchy")
check(prepare.bezelColor != nil, "The model preparation action shares the primary accent treatment")
let modelPageLabels = visibleLabels(in: controller.view)
check(modelPageLabels.contains { $0.stringValue == subtitleToolsString("models.license_hint") },
      "The model page retains the complete usage and territory license notice")
for model in SubtitleToolsModel.fixedModels {
  check(modelPageLabels.contains { $0.stringValue == model.name }, "The model card displays the exact fixed model name: \(model.id)")
  check(modelPageLabels.contains { $0.stringValue == subtitleToolsString("models.role.\(model.id)") },
        "The model card identifies its pipeline role: \(model.id)")
}
check(transport.requests.allSatisfy { $0.command == "status" || $0.command == "verify" }, "Opening either tab never starts an unsolicited model download")
check(deleteButtons.count == 3 && deleteButtons.values.allSatisfy(\.isEnabled), "Every subtitle model has an independently available deletion action")
let deletionAlert = SubtitleToolsModelDeletion.alert(for: service.models.first { $0.id == "asr" }!)
check(deletionAlert.buttons.first?.title == subtitleToolsString("task.cancel") && deletionAlert.buttons.first?.keyEquivalent == "\r"
        && deletionAlert.buttons.last?.keyEquivalent == "", "Deletion confirmation defaults to Cancel, never destructive Enter")
check(deletionAlert.informativeText.contains(subtitleToolsString("models.delete_shared"))
        && deletionAlert.informativeText.contains(subtitleToolsString("models.delete_body")),
      "The confirmation explains shared speech-model impact, permanent residue deletion and preserved outputs")
action(deleteButtons["asr"]!)
check(deletionRequest?.id == "asr" && service.task?.operation != .deleteModel,
      "The real model-card action first requests confirmation for exactly that model")
deletionConfirmation?(false)
check(!transport.requests.contains { $0.command == "delete_model" }, "Cancelling the deletion sheet never sends a deletion request")
if let artifactPath = ProcessInfo.processInfo.environment["SUBTITLE_TEST_ARTIFACT_DIR"],
   let document = (controller.view as? NSScrollView)?.documentView {
  let artifactDirectory = URL(fileURLWithPath: artifactPath, isDirectory: true)
  try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
  let language = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first ?? "unknown"
  for (style, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    panel.appearance = NSAppearance(named: appearanceName)
    for selectedTab in [0, 1] {
      tabs.selectedSegment = selectedTab; action(tabs)
      controller.view.layoutSubtreeIfNeeded()
      controller.viewDidLayout()
      document.layoutSubtreeIfNeeded()
      document.needsDisplay = true
      if let bitmap = document.bitmapImageRepForCachingDisplay(in: document.bounds) {
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
          document.cacheDisplay(in: document.bounds, to: bitmap)
        }
        if let image = bitmap.representation(using: .png, properties: [:]) {
          try image.write(to: artifactDirectory.appendingPathComponent("subtitle-\(language)-\(style)-\(selectedTab).png"))
        }
      }
    }
  }
}
tabs.selectedSegment = 0; action(tabs)

let secondPlayer = PlayerCore()
secondPlayer.info.currentURL = source
let secondController = SubtitleToolsViewController(player: secondPlayer, service: service)
_ = secondController.view
action(generate)
let firstID = service.task!.id
check(transport.requests.last?.command == "start" && transport.requests.last?.inputPath == source.path, "The actual generation action sends the current local file")
check(transport.requests.last?.language == "auto" && transport.requests.last?.burnSubtitles == false, "The IPC request keeps external subtitles as the default")
check(!generate.isEnabled && !prepare.isEnabled && !cancel.isHidden, "A running task disables competing generation and model preparation")
check(!verify.isEnabled && deleteButtons.values.allSatisfy { !$0.isEnabled }, "A running inference also disables local verification and all model deletions")
do { try service.prepareModels(); fatalError("Busy preparation should fail") }
catch SubtitleToolsError.busy { check(true, "The shared service rejects duplicate tasks across windows") }
do { try service.deleteModel(id: "asr"); fatalError("Busy deletion should fail") }
catch SubtitleToolsError.busy { check(true, "The service rejects model deletion while inference is active") }
do { try service.verifyModels(); fatalError("Busy verification should fail") }
catch SubtitleToolsError.busy { check(true, "The service rejects verification while inference is active") }
transport.emit(SubtitleToolsEvent(type: .progress, id: "unrelated", operation: .subtitles, progress: 0.9))
check(service.task?.progress == nil, "Unrelated task progress is ignored")
transport.emit(SubtitleToolsEvent(type: .progress, id: firstID, operation: .subtitles, stage: "asr", progress: 0.25, etaSeconds: 10))
check(service.task?.progress == 0.25 && status.stringValue.contains(subtitleToolsString("stage.asr")), "Real service progress updates the localized native status")

func makeOutputs(_ name: String) throws -> SubtitleToolsOutputs {
  let ass = directory.appendingPathComponent("\(name).ass")
  let srt = directory.appendingPathComponent("\(name).srt")
  try Data("[Script Info]".utf8).write(to: ass)
  try Data("1\n00:00:00,000 --> 00:00:01,000\nText".utf8).write(to: srt)
  return SubtitleToolsOutputs(srt: srt.path, ass: ass.path, video: nil)
}
let firstOutput = try makeOutputs("first")
transport.emit(SubtitleToolsEvent(type: .completed, id: firstID, operation: .subtitles, outputs: firstOutput))
check(service.task?.phase == .completed && !reveal.isHidden, "Valid new sibling outputs complete the task and enable Finder reveal")
check(player.mpv.addedSubtitles == [[firstOutput.ass!, "select"]] && player.mpv.flags["sub-visibility"] == true, "The generating player explicitly selects and displays the new ASS track")
check(secondPlayer.mpv.addedSubtitles.isEmpty, "Another window showing the same file does not claim the generated subtitles")
service.refreshStatus()
transport.ready()
check(player.mpv.addedSubtitles.count == 1, "Later status notifications do not reload a completed subtitle")
let sourceAfterGeneration = try Data(contentsOf: source)
check(sourceAfterGeneration == originalBytes, "External subtitle generation never writes to the source video in this workflow")

languages.selectItem(at: 4)
burn.state = .on
action(generate)
let secondID = service.task!.id
check(transport.requests.last?.language == "ja" && transport.requests.last?.burnSubtitles == true, "Language and explicit burn selections are encoded")
player.videoToolsMediaGeneration += 1
let secondOutput = try makeOutputs("second")
transport.emit(SubtitleToolsEvent(type: .completed, id: secondID, operation: .subtitles, outputs: secondOutput))
check(service.task?.phase == .completed && player.mpv.addedSubtitles.count == 1, "A reloaded source generation does not receive stale automatic subtitles")
check(status.stringValue.contains(subtitleToolsString("status.partial")) && !service.task!.warnings.isEmpty, "A missing requested burn-in video is surfaced without discarding completed external subtitles")

action(generate)
let oldOutputID = service.task!.id
transport.emit(SubtitleToolsEvent(type: .completed, id: oldOutputID, operation: .subtitles, outputs: firstOutput))
check(service.task?.phase == .failed && service.task?.assURL == nil, "Outputs that existed before the task are rejected instead of loading old subtitles")
check(player.mpv.addedSubtitles.count == 1, "Rejected old output never reaches mpv")

action(generate)
let unsafeID = service.task!.id
let unsafeOutput = SubtitleToolsOutputs(srt: "/tmp/foreign-subtitles.srt", ass: "/tmp/foreign-subtitles.ass", video: nil)
transport.emit(SubtitleToolsEvent(type: .completed, id: unsafeID, operation: .subtitles, outputs: unsafeOutput))
check(service.task?.phase == .failed && service.task?.assURL == nil, "Missing or outside-directory output paths are rejected")

let nested = directory.appendingPathComponent("outside-output-folder", isDirectory: true)
try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
let nestedASS = nested.appendingPathComponent("outside.ass")
let nestedSRT = nested.appendingPathComponent("outside.srt")
try Data("Existing external subtitle".utf8).write(to: nestedASS)
try Data("Existing external subtitle".utf8).write(to: nestedSRT)
action(generate)
transport.emit(SubtitleToolsEvent(type: .completed, id: service.task!.id, operation: .subtitles,
                                outputs: SubtitleToolsOutputs(srt: nestedSRT.path, ass: nestedASS.path, video: nil)))
check(service.task?.phase == .failed, "Existing valid files outside the source folder are still rejected")

action(generate)
let symlinkID = service.task!.id
let linkedASS = directory.appendingPathComponent("linked.ass")
let linkedSRT = directory.appendingPathComponent("linked.srt")
try FileManager.default.createSymbolicLink(at: linkedASS, withDestinationURL: URL(fileURLWithPath: firstOutput.ass!))
try FileManager.default.createSymbolicLink(at: linkedSRT, withDestinationURL: URL(fileURLWithPath: firstOutput.srt!))
transport.emit(SubtitleToolsEvent(type: .completed, id: symlinkID, operation: .subtitles,
                                outputs: SubtitleToolsOutputs(srt: linkedSRT.path, ass: linkedASS.path, video: nil)))
check(service.task?.phase == .failed, "New symlink aliases cannot bypass the old-output protection")

action(generate)
let changedURLID = service.task!.id
let changedURLOutput = try makeOutputs("changed-url")
player.info.currentURL = nestedASS
transport.emit(SubtitleToolsEvent(type: .completed, id: changedURLID, operation: .subtitles, outputs: changedURLOutput))
check(service.task?.phase == .completed && player.mpv.addedSubtitles.count == 1, "A different current file blocks automatic subtitle loading even without a generation change")
player.info.currentURL = source
controller.refreshCurrentMedia()

action(generate)
let cancelID = service.task!.id
action(cancel)
check(service.task?.phase == .cancelling && transport.requests.last?.targetID == cancelID, "The native cancel action targets the active task")
check(!cancel.isEnabled, "Cancellation cannot be requested repeatedly")
transport.emit(SubtitleToolsEvent(type: .cancelled, id: cancelID, operation: .subtitles))
check(service.task?.phase == .cancelled && generate.isEnabled, "Cancellation returns the native panel to an actionable state")

let prepareID = try service.prepareModels()
check(cancel.title == subtitleToolsString("models.pause"), "Model preparation uses a pause action rather than a generation cancel label")
transport.emit(SubtitleToolsEvent(type: .progress, id: prepareID, operation: .prepare, stage: "download", progress: 0.5, downloadedBytes: 150, totalBytes: 300, bytesPerSecond: 20, etaSeconds: 7.5, etaScope: "remaining_download"))
let rate = property("rateLabel", of: controller, as: NSTextField.self)
check(rate.stringValue.contains("/s") && rate.stringValue.contains(String(format: subtitleToolsString("task.eta.download"), "00:08")), "Model progress displays download rate and a correctly scoped ETA")
action(cancel)
transport.emit(SubtitleToolsEvent(type: .cancelled, id: prepareID, operation: .prepare))
check(status.stringValue.contains(subtitleToolsString("status.paused")), "Paused model preparation explicitly preserves downloaded data")

var disposablePanel: SubtitleToolsViewController? = SubtitleToolsViewController(player: player, service: service)
_ = disposablePanel?.view
weak var releasedPanel = disposablePanel
let backgroundID = try service.prepareModels()
let cancelRequestsBeforeClosing = transport.requests.filter { $0.command == "cancel" }.count
disposablePanel = nil
check(releasedPanel == nil && service.task?.isActive == true, "Closing a native panel leaves its shared background preparation running")
check(transport.requests.filter { $0.command == "cancel" }.count == cancelRequestsBeforeClosing, "Panel deinitialization does not send a hidden cancel request")
transport.emit(SubtitleToolsEvent(type: .cancelled, id: backgroundID, operation: .prepare))
let idlePlayer = PlayerCore()
idlePlayer.info.state = .idle
let idleController = SubtitleToolsViewController(player: idlePlayer, service: service)
_ = idleController.view
let idleTabs = property("tabs", of: idleController, as: NSSegmentedControl.self)
idleTabs.selectedSegment = 1; action(idleTabs)
check(property("prepareButton", of: idleController, as: NSButton.self).isEnabled,
      "Model management permits preparation without opening a video")
check(!property("generateButton", of: idleController, as: NSButton.self).isEnabled,
      "An empty player disables only subtitle generation")

let smallTransport = SubtitleTransportDouble()
let smallHardware = SubtitleToolsHardware(supportsRuntime: true, physicalMemory: 64 * 1024 * 1024 * 1024)
let smallService = SubtitleToolsService(transport: smallTransport, hardware: smallHardware)
smallService.refreshStatus()
smallTransport.ready()
let smallController = SubtitleToolsViewController(player: player, service: smallService)
_ = smallController.view
let memoryWarning = property("hardwareLabel", of: smallController, as: NSTextField.self)
check(memoryWarning.stringValue == SubtitleToolsError.insufficientMemory.localizedDescription && !memoryWarning.isHiddenOrHasHiddenAncestor,
      "The redesigned panel preserves the full low-memory warning")
do { try smallService.start(inputURL: source, language: "auto", burnSubtitles: false); fatalError("Low memory should fail") }
catch SubtitleToolsError.insufficientMemory { check(true, "Insufficient unified memory blocks generation without selecting smaller models") }
let smallPreparationID = try smallService.prepareModels()
check(!smallPreparationID.isEmpty, "A supported low-memory Mac can pre-download the same fixed models")
let unsupportedService = SubtitleToolsService(transport: SubtitleTransportDouble(), hardware: SubtitleToolsHardware(supportsRuntime: false, physicalMemory: supported.physicalMemory))
do { try unsupportedService.prepareModels(); fatalError("Unsupported hardware should fail") }
catch SubtitleToolsError.unsupportedHardware { check(true, "Unsupported hardware is rejected before helper execution") }

let encoded = try JSONEncoder().encode(SubtitleToolsRequest(id: "request", command: "start", inputPath: source.path, language: "yue", burnSubtitles: false))
let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
check(json["input_path"] as? String == source.path && json["burn_subtitles"] as? Bool == false, "JSONL request field names match the helper protocol")
let decoded = try JSONDecoder().decode(SubtitleToolsEvent.self, from: Data("{\"type\":\"ready\",\"protocol_version\":1}".utf8))
check(decoded.type == .ready && decoded.protocolVersion == 1, "The production event decoder accepts the protocol ready event")
let recoveryTransport = SubtitleTransportDouble()
let recoveryService = SubtitleToolsService(transport: recoveryTransport, hardware: supported)
recoveryService.refreshStatus()
recoveryTransport.ready()
check(recoveryService.isReady, "A matching status response establishes runtime readiness")
recoveryService.refreshStatus()
let staleStatusID = recoveryTransport.requests.last!.id
recoveryTransport.failureHandler?(SubtitleToolsError.helper("Test disconnection"))
check(!recoveryService.isReady && recoveryService.models.allSatisfy { !$0.ready }, "A helper failure invalidates cached model verification")
let verifiedModels = recoveryService.models.map { model -> SubtitleToolsModel in var ready = model; ready.ready = true; return ready }
recoveryTransport.emit(SubtitleToolsEvent(type: .status, id: staleStatusID, runtimeReady: true, models: verifiedModels))
check(!recoveryService.isReady, "A stale status response cannot restore readiness after helper failure")
recoveryService.refreshStatus()
recoveryTransport.ready()
check(recoveryService.isReady && recoveryService.statusError == nil, "A fresh status request can re-establish verified readiness after recovery")

let lifecycleTransport = SubtitleTransportDouble()
let lifecycleService = SubtitleToolsService(transport: lifecycleTransport, hardware: supported)
lifecycleService.refreshStatus()
lifecycleTransport.emitStatus(runtimeReady: false, models: completeUnverified)
let firstScan = lifecycleService.task!.id
check(lifecycleService.task?.operation == .verify, "A new process with complete files starts local verification without downloading")
lifecycleService.cancelCurrent()
lifecycleTransport.emit(SubtitleToolsEvent(type: .cancelled, id: firstScan, operation: .verify))
lifecycleTransport.emitStatus(runtimeReady: false, models: completeUnverified)
lifecycleService.refreshStatus()
lifecycleTransport.emitStatus(runtimeReady: false, models: completeUnverified)
check(lifecycleService.task?.phase == .cancelled && lifecycleTransport.requests.filter { $0.command == "verify" }.count == 1,
      "Cancelling automatic verification does not loop on the following status or panel refresh")
lifecycleTransport.emit(SubtitleToolsEvent(type: .ready, protocolVersion: 1))
lifecycleService.refreshStatus()
lifecycleTransport.emitStatus(runtimeReady: false, models: completeUnverified)
let secondScan = lifecycleService.task!.id
check(secondScan != firstScan && lifecycleTransport.requests.filter { $0.command == "verify" }.count == 2,
      "A fresh helper ready event permits exactly one new local scan after a restart")
lifecycleTransport.emit(SubtitleToolsEvent(type: .failed, id: secondScan, operation: .verify, error: "Fixture hash mismatch"))
lifecycleTransport.emitStatus(runtimeReady: false, models: completeUnverified)
let explicitScan = try lifecycleService.verifyModels()
check(lifecycleTransport.requests.last?.command == "verify" && explicitScan != secondScan,
      "An explicit local verification can be repeated after a failed or cancelled scan")
lifecycleTransport.emit(SubtitleToolsEvent(type: .completed, id: explicitScan, operation: .verify,
                                         runtimeReady: true, models: completeUnverified))
lifecycleTransport.emitStatus(runtimeReady: true, models: completeUnverified)
check(lifecycleTransport.requests.allSatisfy { ["status", "verify", "cancel"].contains($0.command) },
      "Automatic and explicit local checks never send prepare, download, start or summarize commands")

let managementTransport = SubtitleTransportDouble()
let managementService = SubtitleToolsService(transport: managementTransport, hardware: supported)
var allVerified = SubtitleToolsModel.allModels
for index in allVerified.indices {
  allVerified[index].totalBytes = 100
  allVerified[index].downloadedBytes = 100
  allVerified[index].storedBytes = 125
  allVerified[index].ready = true
}
managementService.refreshStatus()
managementTransport.emitStatus(runtimeReady: true, models: allVerified)
do { try managementService.deleteModel(id: "../../foreign"); fatalError("Unknown model should fail") }
catch SubtitleToolsError.invalidInput { check(managementService.task == nil, "Deletion accepts only the fixed model allowlist") }
let deleteID = try managementService.deleteModel(id: "asr")
let deletionJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(managementTransport.requests.last!)) as! [String: Any]
check(deletionJSON["command"] as? String == "delete_model" && deletionJSON["model_id"] as? String == "asr"
        && deletionJSON["input_path"] == nil, "Deletion encodes model_id, not a caller-controlled model path")
let requestsBeforeCancel = managementTransport.requests.count
managementService.cancelCurrent()
check(managementService.task?.phase == .starting && managementTransport.requests.count == requestsBeforeCancel,
      "Model deletion cannot be cancelled halfway through")
for operation in ["delete", "verify", "prepare"] {
  do {
    if operation == "delete" { _ = try managementService.deleteModel(id: "summarizer") }
    else if operation == "verify" { _ = try managementService.verifyModels() }
    else { _ = try managementService.prepareModels() }
    fatalError("Concurrent model work should fail")
  } catch SubtitleToolsError.busy { check(true, "Active deletion blocks competing \(operation) work") }
}
managementTransport.emit(SubtitleToolsEvent(type: .progress, id: deleteID, operation: .deleteModel,
                                          stage: "delete_model", progress: 0.5))
let oldStatus = managementTransport.requests.last(where: { $0.command == "status" })!.id
var deletedModels = allVerified
deletedModels[0].downloadedBytes = 0
deletedModels[0].storedBytes = 0
deletedModels[0].ready = false
managementTransport.emit(SubtitleToolsEvent(type: .completed, id: deleteID, operation: .deleteModel,
                                          stage: "complete", runtimeReady: true, models: deletedModels))
let finalStatus = managementTransport.requests.last(where: { $0.command == "status" })!.id
check(finalStatus != oldStatus, "A model lifecycle terminal event replaces any in-flight pre-completion status request")
managementTransport.emit(SubtitleToolsEvent(type: .status, id: oldStatus, runtimeReady: true, models: allVerified))
check(!managementService.isReady && managementService.summaryReady && managementService.models[0].localBytes == 0,
      "A stale status cannot resurrect deleted model readiness while independent summary weights remain available")
managementTransport.emitStatus(runtimeReady: true, models: deletedModels)
check(managementService.models[1].ready && managementService.models[2].ready && managementService.runtimeReady,
      "Removing one model retains other verified models and runtime readiness")
let expectedStages = ["models.not_downloaded", "models.residue", "models.partial", "models.unverified", "models.invalid", "models.ready"]
var stateProbe = SubtitleToolsModel.fixedModels[0]
stateProbe.totalBytes = 100
var actualStages = [stateProbe.stateKey]
stateProbe.storedBytes = 10; actualStages.append(stateProbe.stateKey)
stateProbe.downloadedBytes = 20; actualStages.append(stateProbe.stateKey)
stateProbe.downloadedBytes = 100; actualStages.append(stateProbe.stateKey)
stateProbe.needsRepair = true; actualStages.append(stateProbe.stateKey)
stateProbe.ready = true; actualStages.append(stateProbe.stateKey)
check(actualStages == expectedStages, "Model states distinguish missing, leftovers, partial, complete, invalid and verified files")
let decodedModel = try JSONDecoder().decode(SubtitleToolsModel.self, from: Data("{\"id\":\"asr\",\"name\":\"Fixture\",\"total_bytes\":100,\"downloaded_bytes\":0,\"ready\":false,\"stored_bytes\":12,\"needs_repair\":true}".utf8))
check(decodedModel.localBytes == 12 && decodedModel.needsRepair == true, "Protocol decoding preserves removable leftovers and verified corruption")
let legacyModel = try JSONDecoder().decode(SubtitleToolsModel.self, from: Data("{\"id\":\"asr\",\"name\":\"Fixture\",\"total_bytes\":100,\"downloaded_bytes\":10,\"ready\":false}".utf8))
check(legacyModel.localBytes == 10 && legacyModel.needsRepair == nil, "Older helper fixtures without optional lifecycle fields remain decodable")
service.shutdown()
check(transport.shutdownCount == 1, "Application shutdown delegates to the helper transport")
print("SUCCESS: \(checks) subtitle checks passed")
