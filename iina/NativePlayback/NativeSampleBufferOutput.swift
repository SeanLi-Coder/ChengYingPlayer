import AVFoundation
import CoreMedia
import Foundation

/// A sample-buffer output with one shared audio/video clock and no application-side frame queue.
/// Create and attach `displayLayer` on the main thread. After initialization, the owner must call
/// every method and read every property (except `onAudioFlush`) on one serial worker queue.
/// The owner supplies a bounded pump and must stop enqueueing before calling `flush` or `shutdown`.
final class NativeSampleBufferOutput {
  enum OutputError: LocalizedError {
    case closed
    case backpressure
    case invalidSample
    case wrongMediaType
    case unsupportedRate
    case invalidTime
    case invalidVolume
    case videoFlushRequired
    case rendererFailed(NSError)

    var errorDescription: String? {
      switch self {
      case .closed: return "The native output has been shut down."
      case .backpressure: return "The native output is not ready for another sample."
      case .invalidSample: return "The sample is invalid, empty, or has no numeric presentation time."
      case .wrongMediaType: return "The sample does not match the selected renderer."
      case .unsupportedRate: return "Native output supports pause and playback rates from 0.5 to 2.0."
      case .invalidTime: return "The native output requires a finite, nonnegative media time."
      case .invalidVolume: return "The native output requires a finite audio volume."
      case .videoFlushRequired: return "The native video renderer requires a flush before decoding can resume."
      case .rendererFailed(let error): return "The native renderer failed (\(error.domain):\(error.code))."
      }
    }
  }

  let displayLayer: AVSampleBufferDisplayLayer
  private let videoRenderer: AVQueuedSampleBufferRendering
  private let audioRenderer: AVSampleBufferAudioRenderer
  private let synchronizer: AVSampleBufferRenderSynchronizer
  private let workerQueue: DispatchQueue?
  private let callbackLock = NSLock()
  private var audioFlushHandler: ((CMTime) -> Void)?
  private var notificationObservers: [NSObjectProtocol] = []
  private var shutdownCompletions: [() -> Void] = []
  private var shutdownComplete = false
  private var closed = false
  private let videoFlushes = DispatchGroup()
  private var pendingVideoFlushes = 0 // Protected by callbackLock; callbacks can arrive on any queue.

  private(set) var lastError: OutputError?
  private(set) var acceptedVideoSamples: UInt64 = 0
  private(set) var acceptedAudioSamples: UInt64 = 0
  private(set) var flushGeneration: UInt64 = 0
  private(set) var requestedRate: Float = 0

  /// Automatic audio flushes and device changes require the owner to flush and seek/refill on
  /// its serial worker queue. Delivery can occur on any thread. This is not an audible-output event.
  var onAudioFlush: ((CMTime) -> Void)? {
    get {
      callbackLock.lock()
      defer { callbackLock.unlock() }
      return audioFlushHandler
    }
    set {
      callbackLock.lock()
      audioFlushHandler = newValue
      callbackLock.unlock()
    }
  }

  init(workerQueue: DispatchQueue? = nil) {
    dispatchPrecondition(condition: .onQueue(.main))
    self.workerQueue = workerQueue
    displayLayer = AVSampleBufferDisplayLayer()
    if #available(macOS 14.0, *) {
      videoRenderer = displayLayer.sampleBufferRenderer
    } else {
      videoRenderer = displayLayer
    }
    audioRenderer = AVSampleBufferAudioRenderer()
    synchronizer = AVSampleBufferRenderSynchronizer()
    displayLayer.videoGravity = .resizeAspect
    audioRenderer.volume = 0
    audioRenderer.audioTimePitchAlgorithm = .spectral
    // The modern renderer supports background enqueueing. Do not mix its
    // AVQueuedSampleBufferRendering methods with those of the display layer.
    synchronizer.addRenderer(videoRenderer)
    synchronizer.addRenderer(audioRenderer)
    // An absent audio track must not hold a video-only file in the startup wait state.
    // The owner primes both present streams before starting the shared clock.
    synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
    synchronizer.setRate(0, time: .zero)

    let center = NotificationCenter.default
    notificationObservers.append(center.addObserver(
      forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
      object: audioRenderer, queue: nil
    ) { [weak self] notification in
      guard let self = self else { return }
      let time = (notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
      self.deliverAudioFlush(time ?? self.synchronizer.currentTime())
    })
    notificationObservers.append(center.addObserver(
      forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange,
      object: audioRenderer, queue: nil
    ) { [weak self] _ in
      guard let self = self else { return }
      self.deliverAudioFlush(self.synchronizer.currentTime())
    })
  }

  deinit {
    notificationObservers.forEach(NotificationCenter.default.removeObserver)
  }

  var currentTime: CMTime {
    requireWorkerQueue()
    return synchronizer.currentTime()
  }

  /// Unlike `requestedRate`, this reads the asynchronously updated underlying timebase.
  var actualRate: Double {
    requireWorkerQueue()
    return CMTimebaseGetRate(synchronizer.timebase)
  }

  var volume: Float {
    requireWorkerQueue()
    return audioRenderer.volume
  }

  /// This is a renderer failure, not proof that frames have been displayed or audio heard.
  var error: OutputError? {
    requireWorkerQueue()
    // A pending flush resets the old video error asynchronously. Its old
    // status must not fail the replacement generation before completion.
    if !isFlushingVideo {
      if let error = videoError { return .rendererFailed(error as NSError) }
      if videoRequiresFlush { return .videoFlushRequired }
    }
    if let error = audioRenderer.error { return .rendererFailed(error as NSError) }
    return lastError
  }

  var isFlushingVideo: Bool {
    requireWorkerQueue()
    callbackLock.lock()
    defer { callbackLock.unlock() }
    return pendingVideoFlushes > 0
  }

  func isReady(video: Bool) -> Bool {
    requireWorkerQueue()
    guard !closed, !isFlushingVideo else { return false }
    if video {
      return videoStatus != .failed && videoError == nil && !videoRequiresFlush && videoRenderer.isReadyForMoreMediaData
    }
    return audioRenderer.status != .failed && audioRenderer.isReadyForMoreMediaData
  }

  func enqueue(_ sample: CMSampleBuffer, video: Bool) throws {
    requireWorkerQueue()
    guard !closed else { throw OutputError.closed }
    guard CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample),
          CMSampleBufferGetNumSamples(sample) > 0,
          CMSampleBufferGetPresentationTimeStamp(sample).isNumeric else {
      throw OutputError.invalidSample
    }
    guard let format = CMSampleBufferGetFormatDescription(sample),
          CMFormatDescriptionGetMediaType(format) == (video ? kCMMediaType_Video : kCMMediaType_Audio) else {
      throw OutputError.wrongMediaType
    }
    guard !isFlushingVideo else { throw OutputError.backpressure }
    if let error = video ? videoError : audioRenderer.error {
      throw OutputError.rendererFailed(error as NSError)
    }
    guard isReady(video: video) else { throw OutputError.backpressure }
    if video {
      videoRenderer.enqueue(sample)
      acceptedVideoSamples &+= 1
    } else {
      audioRenderer.enqueue(sample)
      acceptedAudioSamples &+= 1
    }
    lastError = nil
  }

  /// Changes the common clock without flushing. A seek requires pause, flush, then an anchored rate.
  /// AVFoundation updates the timebase asynchronously; `currentTime` may briefly precede the request.
  @discardableResult
  func setRate(_ rate: Float, at time: CMTime? = nil) -> Bool {
    requireWorkerQueue()
    guard !closed else { lastError = .closed; return false }
    guard rate.isFinite, rate == 0 || (0.5...2.0).contains(rate) else {
      lastError = .unsupportedRate
      return false
    }
    if let time = time, !time.isNumeric || !time.seconds.isFinite || CMTimeCompare(time, .zero) < 0 {
      lastError = .invalidTime
      return false
    }
    requestedRate = rate
    lastError = nil
    synchronizer.setRate(rate, time: time ?? .invalid)
    return true
  }

  func setVolume(_ volume: Float) {
    requireWorkerQueue()
    guard !closed else { lastError = .closed; return }
    guard volume.isFinite else { lastError = .invalidVolume; return }
    audioRenderer.volume = min(1, max(0, volume))
    lastError = nil
  }

  /// Invalidates both queues. Readiness remains false until every asynchronous video flush completes.
  /// The owner must also discard samples from its previous seek generation.
  func flush(removeImage: Bool) {
    requireWorkerQueue()
    guard !closed else { return }
    audioRenderer.flush()
    flushVideo(removeImage: removeImage)
    acceptedVideoSamples = 0
    acceptedAudioSamples = 0
    flushGeneration &+= 1
    lastError = nil
  }

  /// Stops synchronously on the worker, then removes renderers asynchronously. Completion always
  /// arrives asynchronously on main. There is no synchronous main dispatch or renderer wait.
  func shutdown(completion: @escaping () -> Void) {
    requireWorkerQueue()
    callbackLock.lock()
    if shutdownComplete {
      callbackLock.unlock()
      DispatchQueue.main.async(execute: completion)
      return
    }
    shutdownCompletions.append(completion)
    callbackLock.unlock()
    guard !closed else { return }
    closed = true
    onAudioFlush = nil
    notificationObservers.forEach(NotificationCenter.default.removeObserver)
    notificationObservers.removeAll()
    requestedRate = 0
    synchronizer.setRate(0, time: .invalid)
    audioRenderer.stopRequestingMediaData()
    videoRenderer.stopRequestingMediaData()
    audioRenderer.flush()
    flushVideo(removeImage: true)
    let removals = DispatchGroup()
    removals.enter()
    synchronizer.removeRenderer(videoRenderer, at: .invalid) { _ in removals.leave() }
    removals.enter()
    synchronizer.removeRenderer(audioRenderer, at: .invalid) { _ in removals.leave() }
    removals.enter()
    videoFlushes.notify(queue: .global(qos: .utility)) { removals.leave() }
    removals.notify(queue: .main) { [self] in
      callbackLock.lock()
      shutdownComplete = true
      let completions = shutdownCompletions
      shutdownCompletions.removeAll()
      callbackLock.unlock()
      completions.forEach { $0() }
    }
  }

  private func deliverAudioFlush(_ time: CMTime) {
    callbackLock.lock()
    let handler = audioFlushHandler
    callbackLock.unlock()
    handler?(time)
  }

  private var videoError: Error? {
    if #available(macOS 14.0, *) { return (videoRenderer as! AVSampleBufferVideoRenderer).error }
    return displayLayer.error
  }

  private var videoStatus: AVQueuedSampleBufferRenderingStatus {
    if #available(macOS 14.0, *) { return (videoRenderer as! AVSampleBufferVideoRenderer).status }
    return displayLayer.status
  }

  private var videoRequiresFlush: Bool {
    if #available(macOS 14.0, *) { return (videoRenderer as! AVSampleBufferVideoRenderer).requiresFlushToResumeDecoding }
    return displayLayer.requiresFlushToResumeDecoding
  }

  private func flushVideo(removeImage: Bool) {
    if #available(macOS 14.0, *) {
      callbackLock.lock()
      pendingVideoFlushes += 1
      callbackLock.unlock()
      videoFlushes.enter()
      (videoRenderer as! AVSampleBufferVideoRenderer).flush(removingDisplayedImage: removeImage) { [self] in
        callbackLock.lock()
        pendingVideoFlushes -= 1
        callbackLock.unlock()
        videoFlushes.leave()
      }
    } else if removeImage {
      displayLayer.flushAndRemoveImage()
    } else {
      videoRenderer.flush()
    }
  }

  private func requireWorkerQueue() {
    if let workerQueue = workerQueue { dispatchPrecondition(condition: .onQueue(workerQueue)) }
  }
}
