import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

var passed = 0
var failed = 0
func check(_ value: @autoclosure () -> Bool, _ description: String) {
  if value() { passed += 1; print("PASS: \(description)") }
  else { failed += 1; print("FAIL: \(description)") }
}

func waitUntil(_ seconds: TimeInterval = 3, _ predicate: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  repeat {
    if predicate() { return true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
  } while Date() < deadline
  return predicate()
}

func videoSample(at seconds: Double) -> CMSampleBuffer {
  var pixel: CVPixelBuffer?
  precondition(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess)
  let image = pixel!
  CVPixelBufferLockBaseAddress(image, [])
  memset(CVPixelBufferGetBaseAddress(image), 0x40, CVPixelBufferGetDataSize(image))
  CVPixelBufferUnlockBaseAddress(image, [])
  var format: CMVideoFormatDescription?
  precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
    imageBuffer: image, formatDescriptionOut: &format) == noErr)
  var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
    presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600), decodeTimeStamp: .invalid)
  var sample: CMSampleBuffer?
  precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
    imageBuffer: image, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
  return sample!
}

func audioSample(at seconds: Double) -> CMSampleBuffer {
  let frames = 1024
  var stream = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
    mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
  var format: CMAudioFormatDescription?
  precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &stream,
    layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
    formatDescriptionOut: &format) == noErr)
  var data: CMBlockBuffer?
  precondition(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
    blockLength: frames * 8, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
    offsetToData: 0, dataLength: frames * 8, flags: 0, blockBufferOut: &data) == noErr)
  precondition(CMBlockBufferFillDataBytes(with: 0, blockBuffer: data!, offsetIntoDestination: 0,
    dataLength: frames * 8) == noErr)
  var sample: CMSampleBuffer?
  precondition(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
    dataBuffer: data!, formatDescription: format!, sampleCount: frames,
    presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000),
    packetDescriptions: nil, sampleBufferOut: &sample) == noErr)
  return sample!
}

_ = NSApplication.shared
let worker = DispatchQueue(label: "NativeSampleBufferOutputTests.worker")
let output = NativeSampleBufferOutput(workerQueue: worker)
if CommandLine.arguments.contains("--reject-main-shutdown") {
  // This mode is launched only by the negative ownership test below.
  output.shutdown { exit(65) }
  exit(66)
}
let layerHost = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
layerHost.wantsLayer = true
output.displayLayer.frame = layerHost.bounds
layerHost.layer!.addSublayer(output.displayLayer)
let attachedSynchronizer = Mirror(reflecting: output).children.first { $0.label == "synchronizer" }!.value
  as! AVSampleBufferRenderSynchronizer
if #available(macOS 14.0, *) {
  check(attachedSynchronizer.renderers.contains { ($0 as AnyObject) === output.displayLayer.sampleBufferRenderer },
    "Modern output attaches the background-safe video renderer to the shared clock")
  check(!attachedSynchronizer.renderers.contains { ($0 as AnyObject) === output.displayLayer },
    "Modern output does not mix display-layer and sample-renderer queue APIs")
}

worker.sync {
  check(output.volume == 0, "Every output starts with zero volume")
  check(output.requestedRate == 0, "Every output starts paused")
  check(output.displayLayer.videoGravity == .resizeAspect, "Video preserves aspect ratio")
  output.setVolume(0.7)
  check(abs(output.volume - 0.7) < 0.0001, "Volume commands reach the audio renderer")
  output.setVolume(-1)
  check(output.volume == 0, "Volume clamps to silence at its lower bound")
  output.setVolume(2)
  check(output.volume == 1, "Volume clamps to full scale at its upper bound")
  output.setVolume(.nan)
  check(output.volume == 1 && output.lastError != nil, "Nonfinite volume cannot poison renderer state")
  output.setVolume(0)
  check(!output.setRate(-1), "Reverse rate is rejected")
  check(!output.setRate(.nan), "Nonfinite rate is rejected")
  check(!output.setRate(0.1), "Unqualified slow playback rate is rejected")
  check(!output.setRate(4), "Unqualified fast playback rate is rejected")
  check(!output.setRate(1, at: CMTime(value: -1, timescale: 1)), "Negative anchor is rejected")
  check(!output.setRate(1, at: .positiveInfinity), "Infinite anchor is rejected")
  check(output.setRate(0, at: .zero), "Pause accepts a valid anchor")
  let video = videoSample(at: 0)
  let audio = audioSample(at: 0)
  do { try output.enqueue(video, video: false); check(false, "Wrong stream is rejected") }
  catch NativeSampleBufferOutput.OutputError.wrongMediaType { check(true, "Wrong stream is rejected") }
  catch { check(false, "Wrong stream reports its media mismatch") }
  do { try output.enqueue(audio, video: true); check(false, "Audio cannot enter video renderer") }
  catch NativeSampleBufferOutput.OutputError.wrongMediaType { check(true, "Audio cannot enter video renderer") }
  catch { check(false, "Audio mismatch reports its media mismatch") }
  CMSampleBufferInvalidate(audio)
  do { try output.enqueue(audio, video: false); check(false, "Invalidated sample is rejected") }
  catch NativeSampleBufferOutput.OutputError.invalidSample { check(true, "Invalidated sample is rejected") }
  catch { check(false, "Invalidated sample reports its invalid state") }
}

check(waitUntil { worker.sync { output.isReady(video: true) && output.isReady(video: false) } },
  "Both renderers become ready for real uncompressed samples")
worker.sync {
  do {
    try output.enqueue(videoSample(at: 0), video: true)
    try output.enqueue(audioSample(at: 0), video: false)
    check(output.acceptedVideoSamples == 1, "A CVPixelBuffer sample is accepted")
    check(output.acceptedAudioSamples == 1, "A silent PCM sample is accepted")
  } catch { check(false, "Real samples enqueue successfully: \(error.localizedDescription)") }
  check(output.setRate(1, at: .zero), "Shared clock can begin playing")
}
check(waitUntil { worker.sync { output.currentTime.isNumeric && output.currentTime.seconds > 0.08 } },
  "The shared media clock actually advances")
check(waitUntil { worker.sync { output.actualRate == 1 } }, "Actual timebase rate reaches the playback request")
worker.sync { _ = output.setRate(0) }
_ = waitUntil(0.1) { false }
let pausedTime = worker.sync { output.currentTime.seconds }
_ = waitUntil(0.12) { false }
check(worker.sync { abs(output.currentTime.seconds - pausedTime) < 0.01 }, "Pause stops the shared media clock")
check(waitUntil { worker.sync { output.actualRate == 0 } }, "Actual timebase rate confirms the pause")

worker.sync {
  output.flush(removeImage: true)
  check(output.flushGeneration == 1, "Seek flush advances the queue generation")
  check(output.acceptedVideoSamples == 0 && output.acceptedAudioSamples == 0,
    "Seek flush clears accounting for both old queues")
  check(output.setRate(0, at: CMTime(seconds: 5, preferredTimescale: 600)), "Seek sets a new common anchor")
}
check(waitUntil { worker.sync { output.actualRate == 0 && abs(output.currentTime.seconds - 5) <= 0.001 } },
  "Asynchronous timebase update reaches the seek anchor")
check(waitUntil { worker.sync { output.isReady(video: true) } }, "Video accepts new samples after seek flush")
worker.sync {
  do { try output.enqueue(videoSample(at: 5), video: true) }
  catch { check(false, "First post-seek sample is accepted: \(error.localizedDescription)") }
  var attempts = 0
  while output.isReady(video: true), attempts < 128 {
    do { try output.enqueue(videoSample(at: 5 + Double(attempts + 1) / 30), video: true) }
    catch { break }
    attempts += 1
  }
  check(attempts < 128, "Paused renderer applies bounded backpressure")
  // Readiness can recover while constructing a buffer. Assert against an actual rejection,
  // rather than assuming that a prior readiness observation is still false at the next call.
  var rejected = false
  for index in 0..<128 {
    let sample = videoSample(at: 10 + Double(index) / 30)
    let accepted = output.acceptedVideoSamples
    do { try output.enqueue(sample, video: true) }
    catch NativeSampleBufferOutput.OutputError.backpressure {
      rejected = true
      check(output.acceptedVideoSamples == accepted, "Rejected samples do not enter an application queue")
      break
    } catch { check(false, "Backpressure reports the correct category"); break }
  }
  check(rejected, "Backpressure rejects rather than buffers")
  output.flush(removeImage: true)
}

// White-box notification fixture exercises the actual observer, with no device or account changes.
let audioRenderer = Mirror(reflecting: output).children.first { $0.label == "audioRenderer" }!.value
let notificationLock = NSLock()
var observedFlushTimes: [CMTime] = []
output.onAudioFlush = { time in
  notificationLock.lock()
  observedFlushTimes.append(time)
  notificationLock.unlock()
}
worker.sync {
  NotificationCenter.default.post(name: .AVSampleBufferAudioRendererWasFlushedAutomatically,
    object: audioRenderer, userInfo: [AVSampleBufferAudioRendererFlushTimeKey: NSValue(time: CMTime(value: 7, timescale: 1))])
  NotificationCenter.default.post(name: .AVSampleBufferAudioRendererOutputConfigurationDidChange,
    object: audioRenderer)
}
notificationLock.lock()
check(observedFlushTimes.count == 2, "Automatic flush and route configuration notifications both reach the owner")
check(observedFlushTimes.first?.seconds == 7, "Automatic flush preserves its restart timestamp")
notificationLock.unlock()

var completed = 0
let shutdownStarted = Date()
worker.sync {
  output.shutdown { check(Thread.isMainThread, "Shutdown completion is delivered on main"); completed += 1 }
  output.shutdown { completed += 1 }
  check(!output.isReady(video: true) && !output.isReady(video: false), "Shutdown rejects both streams immediately")
  check(!output.setRate(1), "Shutdown cannot restart playback")
  do { try output.enqueue(videoSample(at: 0), video: true); check(false, "Shutdown rejects new samples") }
  catch NativeSampleBufferOutput.OutputError.closed { check(true, "Shutdown rejects new samples") }
  catch { check(false, "Closed output reports the correct category") }
}
check(Date().timeIntervalSince(shutdownStarted) < 1, "Shutdown returns without a main-thread wait")
check(waitUntil(5) { completed == 2 }, "Asynchronous renderer removal completes all callers")
check(worker.sync { !output.isFlushingVideo }, "Shutdown completion awaits all asynchronous video flushes")
let synchronizer = Mirror(reflecting: output).children.first { $0.label == "synchronizer" }!.value
  as! AVSampleBufferRenderSynchronizer
check(synchronizer.renderers.isEmpty, "Shutdown actually detaches both renderers from the common clock")
worker.sync { output.shutdown { completed += 1 } }
check(waitUntil { completed == 3 }, "Repeated shutdown after completion still completes asynchronously")
worker.sync {
  NotificationCenter.default.post(name: .AVSampleBufferAudioRendererWasFlushedAutomatically,
    object: audioRenderer)
}
notificationLock.lock()
check(observedFlushTimes.count == 2, "Shutdown disconnects audio flush notifications")
notificationLock.unlock()
output.displayLayer.removeFromSuperlayer()

for cycle in 0..<12 {
  var cyclingOutput: NativeSampleBufferOutput? = NativeSampleBufferOutput(workerQueue: worker)
  weak var releasedOutput = cyclingOutput
  var cycleCompleted = false
  worker.sync {
    guard let candidate = cyclingOutput else { preconditionFailure("Missing cycle output") }
    check(candidate.volume == 0, "Reopen cycle \(cycle) resets volume")
    _ = candidate.setRate(0, at: .zero)
    if candidate.isReady(video: true) { try? candidate.enqueue(videoSample(at: 0), video: true) }
    if candidate.isReady(video: false) { try? candidate.enqueue(audioSample(at: 0), video: false) }
    check(candidate.setRate(cycle % 2 == 0 ? 0.5 : 2), "Reopen cycle \(cycle) accepts qualified rate")
    candidate.flush(removeImage: true)
    candidate.shutdown { cycleCompleted = true }
  }
  check(waitUntil(5) { cycleCompleted }, "Reopen cycle \(cycle) completes asynchronous shutdown")
  cyclingOutput = nil
  check(waitUntil { releasedOutput == nil }, "Reopen cycle \(cycle) releases output and observer ownership")
  releasedOutput = nil
}
let wrongQueue = Process()
wrongQueue.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
wrongQueue.arguments = ["--reject-main-shutdown"]
wrongQueue.standardOutput = FileHandle.nullDevice
wrongQueue.standardError = FileHandle.nullDevice
do {
  try wrongQueue.run()
  if waitUntil(5, { !wrongQueue.isRunning }) {
    check(wrongQueue.terminationReason == .uncaughtSignal &&
      [SIGTRAP, SIGILL].contains(wrongQueue.terminationStatus),
      "Main-queue shutdown misuse is rejected by the worker ownership assertion")
  } else {
    wrongQueue.terminate()
    _ = waitUntil(2) { !wrongQueue.isRunning }
    check(false, "The negative ownership subprocess terminates within its deadline")
  }
} catch { check(false, "The negative ownership subprocess starts") }
print("Native output checks: \(passed) passed, \(failed) failed. Accepted samples and clock progress do not prove displayed pixels or audible output.")
exit(failed == 0 ? 0 : 1)
