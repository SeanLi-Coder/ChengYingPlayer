import Foundation
import AVFoundation

enum NativePlaybackPhase: String {
  case idle, opening, seeking, paused, playing, ended, failed, closed
}

struct NativePlaybackSnapshot {
  let generation: UInt64
  let revision: UInt64
  let phase: NativePlaybackPhase
  let position: Double
  let duration: Double
  let volume: Float
  let rate: Float
  let media: CYNMediaInfo?
  let videoSamples: Int
  let audioSamples: Int
  let hardwareVideoSamples: Int
  let videoToolboxSamples: Int
  let queuedBytes: Int
  let failure: NativePlaybackFailure?
}

enum NativePlaybackQueryResult {
  case ready(NativePlaybackSnapshot)
  case unavailable
  case superseded
}

struct NativePlaybackSampleObservation {
  let generation: UInt64
  let revision: UInt64
  let video: Bool
  let start: Double
  let end: Double
  let hardwareDecoded: Bool
  let videoToolboxDecoded: Bool
}

/// Locking is limited to cancellation and request identity. FFmpeg, output
/// commands and sample ownership always remain on the session's serial queue.
private final class NativePlaybackRequestIdentity {
  private let lock = NSLock()
  private var revision: UInt64 = 0
  private var mediaRevision: UInt64 = 0
  private var decoder: CYNMediaDecoder?

  func advance(cancel: Bool) -> UInt64 {
    lock.lock()
    revision &+= 1
    let value = revision
    if cancel { mediaRevision &+= 1; decoder?.cancel() }
    lock.unlock()
    return value
  }

  func accepts(_ value: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return revision == value
  }

  func current() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return revision
  }

  func currentMedia() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return mediaRevision
  }

  func acceptsMedia(_ value: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return mediaRevision == value
  }

  func install(_ decoder: CYNMediaDecoder?, revision value: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard value == revision else { return false }
    self.decoder = decoder
    return true
  }
}

/// An independent FFmpeg/sample-buffer playback session. It does not call mpv
/// or load user mpv configuration. Construct and send commands on main; all
/// blocking demux/decode work and output queue mutations run off main.
///
/// This is the migration backend, not a claim of feature parity. Unsupported
/// media fails explicitly; callers must not label a compatibility retry as a
/// successful native playback verification.
final class NativePlaybackSession {
  let output: NativeSampleBufferOutput
  var onSnapshot: ((NativePlaybackSnapshot) -> Void)?

  /// Optional diagnostics execute on the worker. They must be cheap, must not
  /// retain media buffers, and must not call session commands synchronously.
  private let sampleObserver: ((NativePlaybackSampleObservation) -> Void)?
  private let worker = DispatchQueue(label: "com.chengying.native-playback", qos: .userInitiated,
                                     autoreleaseFrequency: .workItem)
  private let identity = NativePlaybackRequestIdentity()
  private var nextGeneration: UInt64 = 0 // Main only.
  private var terminal = false // Main only.
  private var mainPhase: NativePlaybackPhase = .idle // Main only.
  private var preferredRate: Float = 1 // Main only; applies to the next open.
  private var preferredRepeatFile = false // Main only; A/B markers stay per media.

  // Everything below belongs to worker, except immutable limits.
  private var generation: UInt64 = 0
  private var revision: UInt64 = 0
  private var decoder: CYNMediaDecoder?
  private var media: CYNMediaInfo?
  private var phase: NativePlaybackPhase = .idle
  private var failure: NativePlaybackFailure?
  private var volume: Float = 0
  private var rate: Float = 1
  private var wantsPlayback = false
  private var loop: NativePlaybackInterval?
  private var repeatFile = false
  private var lowerBound: Double = 0
  private var pending: CYNMediaSample?
  private var eof = false
  private var videoBoundary = false
  private var audioBoundary = false
  private var hasVideo = false
  private var hasAudio = false
  private var preroll = false
  private var prerollStarted: TimeInterval = 0
  private var prerollSamples = 0
  private var prerollBackpressure = false
  private var finalEnd: Double = 0
  private var videoSamples = 0
  private var audioSamples = 0
  private var hardwareVideoSamples = 0
  private var videoToolboxSamples = 0
  private var scheduledPump: UInt64 = 0
  private var lastSnapshotTime: TimeInterval = 0
  private var outstanding: [(end: Double, bytes: Int)] = []
  private var queuedBytes = 0
  private var recentOutputFlushes: [TimeInterval] = []
  private let maximumQueuedBytes = 128 * 1024 * 1024
  private let maximumLead: Double = 0.5

  init(sampleObserver: ((NativePlaybackSampleObservation) -> Void)? = nil) {
    dispatchPrecondition(condition: .onQueue(.main))
    output = NativeSampleBufferOutput(workerQueue: worker)
    self.sampleObserver = sampleObserver
    output.onAudioFlush = { [weak self] _ in
      guard let self else { return }
      let eventRevision = self.identity.current()
      self.worker.async { [weak self] in
        guard let self, self.identity.accepts(eventRevision), self.revision == eventRevision,
              self.decoder != nil, self.media != nil,
              ![.closed, .idle, .failed, .ended].contains(self.phase) else { return }
        // A device change can discard audio while preroll is still pending.
        // Refill both tracks even in opening/seeking, rather than leaving an
        // obsolete audio-ready flag behind. Bound recovery if a broken output
        // repeatedly flushes during refill, instead of retrying forever.
        let now = ProcessInfo.processInfo.systemUptime
        self.recentOutputFlushes.removeAll { now - $0 > 10 }
        guard self.recentOutputFlushes.count < 3 else {
          self.fail(NativePlaybackFailure.outputRecoveryLimit, revision: eventRevision)
          return
        }
        self.recentOutputFlushes.append(now)
        self.seekOnWorker(to: self.positionOnWorker(), revision: self.revision)
      }
    }
  }

  deinit {
    _ = identity.advance(cancel: true)
    let reader = decoder
    let sink = output
    worker.async {
      reader?.close()
      sink.shutdown(completion: {})
    }
  }

  func open(_ url: URL, autoplay: Bool = true) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !terminal else { return }
    nextGeneration &+= 1
    mainPhase = .opening
    let generation = nextGeneration
    let initialRate = preferredRate
    let initialRepeatFile = preferredRepeatFile
    let request = identity.advance(cancel: true)
    worker.async { [weak self] in
      guard let self, self.identity.accepts(request) else { return }
      self.resetOnWorker()
      self.revision = request
      self.generation = generation
      self.phase = .opening
      self.rate = initialRate
      self.repeatFile = initialRepeatFile
      self.volume = 0
      self.output.setVolume(0)
      self.wantsPlayback = autoplay
      self.publish(force: true)
      let reader = CYNMediaDecoder()
      guard self.identity.install(reader, revision: request) else { return }
      self.decoder = reader
      do {
        guard let description = try reader.open(url) else {
          throw NativePlaybackFailure.malformedSample
        }
        guard self.identity.accepts(request) else { reader.close(); return }
        self.media = description
        self.hasVideo = !description.hasVideo
        self.hasAudio = !description.hasAudio
        self.preroll = true
        self.prerollStarted = ProcessInfo.processInfo.systemUptime
        self.output.setRate(0, at: .zero)
        self.pump()
      } catch { self.fail(error, revision: request) }
    }
  }

  func setPaused(_ paused: Bool) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !terminal else { return }
    let mediaRequest = identity.currentMedia()
    worker.async { [weak self] in
      guard let self, self.identity.acceptsMedia(mediaRequest), self.decoder != nil,
            ![.failed, .closed, .idle].contains(self.phase) else { return }
      self.wantsPlayback = !paused
      guard self.identity.accepts(self.revision) else { return }
      if self.preroll { return }
      // A redundant pause at EOF must not erase the state needed to restart
      // from the beginning on the next explicit resume.
      if paused && self.phase == .ended { return }
      if !paused && self.phase == .ended {
        self.seekOnWorker(to: self.loop?.start ?? 0, revision: self.revision)
        return
      }
      self.output.setRate(paused ? 0 : self.rate)
      self.phase = paused ? .paused : .playing
      self.publish(force: true)
      if !paused { self.schedulePump() }
    }
  }

  func setVolume(_ requested: Float) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !terminal, requested.isFinite else { return }
    let mediaRequest = identity.currentMedia()
    worker.async { [weak self] in
      guard let self, self.identity.acceptsMedia(mediaRequest) else { return }
      self.volume = min(1, max(0, requested))
      self.output.setVolume(self.volume)
      self.publish(force: true)
    }
  }

  /// Capture the worker's playback state without blocking AppKit. A marker or
  /// preview snapshot must use this instead of the periodic UI cache. Changing
  /// media or seeking before delivery invalidates the result explicitly; every
  /// request completes once on main, including shutdown and owner destruction.
  func captureCurrentState(completion: @escaping (NativePlaybackQueryResult) -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !terminal else {
      DispatchQueue.main.async { completion(.unavailable) }
      return
    }
    let request = identity.current()
    worker.async { [weak self] in
      guard let self, self.identity.accepts(request), self.revision == request else {
        DispatchQueue.main.async { completion(.superseded) }
        return
      }
      let result: NativePlaybackQueryResult
      if self.media != nil, [.playing, .paused, .ended].contains(self.phase), !self.preroll {
        result = .ready(self.snapshotOnWorker())
      } else {
        result = .unavailable
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.identity.accepts(request), !self.terminal else {
          completion(.superseded)
          return
        }
        completion(result)
      }
    }
  }

  /// Return false for unsupported rates rather than silently muting the audio.
  @discardableResult
  func setRate(_ requested: Float) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !terminal, requested.isFinite, (0.5...2).contains(requested) else { return false }
    preferredRate = requested
    let mediaRequest = identity.currentMedia()
    worker.async { [weak self] in
      guard let self, self.identity.acceptsMedia(mediaRequest) else { return }
      self.rate = requested
      // A renderer may automatically flush when its pitch/rate changes. Seek
      // and refill both streams as one transaction, not just the audio stream.
      if self.decoder != nil && self.identity.accepts(self.revision) {
        self.seekOnWorker(to: self.positionOnWorker(), revision: self.revision)
      }
    }
    return true
  }

  @discardableResult
  func seek(to seconds: Double) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !terminal, seconds.isFinite, seconds >= 0,
          [.playing, .paused, .seeking, .ended].contains(mainPhase) else { return false }
    mainPhase = .seeking
    let request = identity.advance(cancel: false)
    worker.async { [weak self] in
      guard let self, self.identity.accepts(request) else { return }
      self.seekOnWorker(to: seconds, revision: request)
    }
    return true
  }

  func setLoop(_ interval: NativePlaybackInterval?, repeatFile: Bool? = nil) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !terminal else { return }
    let repeatMode = repeatFile ?? preferredRepeatFile
    preferredRepeatFile = repeatMode
    let mediaRequest = identity.currentMedia()
    worker.async { [weak self] in
      guard let self, self.identity.acceptsMedia(mediaRequest) else { return }
      self.loop = interval
      self.repeatFile = repeatMode
      // Buffers already enqueued can extend past a new B point. Always flush
      // and gate again, even if the current playhead is already within A/B.
      if self.decoder != nil && self.identity.accepts(self.revision) {
        self.seekOnWorker(to: self.positionOnWorker(), revision: self.revision)
      }
    }
  }

  func stop() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !terminal else { return }
    mainPhase = .idle
    let request = identity.advance(cancel: true)
    worker.async { [weak self] in
      guard let self, self.identity.accepts(request) else { return }
      self.resetOnWorker()
      self.revision = request
      self.phase = .idle
      _ = self.identity.install(nil, revision: request)
      self.publish(force: true)
    }
  }

  func shutdown(completion: @escaping () -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !terminal else {
      worker.async { [output] in output.shutdown(completion: completion) }
      return
    }
    terminal = true
    mainPhase = .closed
    let request = identity.advance(cancel: true)
    worker.async { [self] in
      resetOnWorker()
      revision = request
      phase = .closed
      _ = identity.install(nil, revision: request)
      publish(force: true)
      output.shutdown(completion: completion)
    }
  }

  private func resetOnWorker() {
    scheduledPump &+= 1
    output.setRate(0)
    output.flush(removeImage: true)
    decoder?.close()
    decoder = nil
    media = nil
    pending = nil
    loop = nil
    failure = nil
    eof = false
    videoBoundary = false
    audioBoundary = false
    preroll = false
    prerollSamples = 0
    prerollBackpressure = false
    wantsPlayback = false
    lowerBound = 0
    finalEnd = 0
    outstanding.removeAll(keepingCapacity: true)
    queuedBytes = 0
    recentOutputFlushes.removeAll(keepingCapacity: true)
    videoSamples = 0
    audioSamples = 0
    hardwareVideoSamples = 0
    videoToolboxSamples = 0
  }

  /// Shared with the main-thread transport's accepted seek intent. Keeping the
  /// exact floor/ceiling here prevents a UI pending target outside an active loop.
  static func clampedSeekTarget(_ seconds: Double, duration: Double, loop: NativePlaybackInterval?) -> Double {
    let mediaEnd = duration.isFinite && duration > 0 ? duration : Double.greatestFiniteMagnitude
    let ceiling = min(mediaEnd, loop?.end ?? mediaEnd)
    let floor = loop?.start ?? 0
    return min(max(floor, seconds), max(floor, ceiling - 0.000001))
  }

  private func seekOnWorker(to seconds: Double, revision request: UInt64) {
    guard let decoder, let media, identity.accepts(request), phase != .failed else { return }
    revision = request
    scheduledPump &+= 1
    let mediaEnd = media.duration.isFinite && media.duration > 0 ? media.duration : Double.greatestFiniteMagnitude
    if let loop, loop.end > mediaEnd {
      fail(NativePlaybackFailure.invalidRange, revision: request)
      return
    }
    let target = Self.clampedSeekTarget(seconds, duration: media.duration, loop: loop)
    output.setRate(0)
    output.flush(removeImage: true)
    pending = nil
    outstanding.removeAll(keepingCapacity: true)
    queuedBytes = 0
    eof = false
    videoBoundary = false
    audioBoundary = false
    hasVideo = !media.hasVideo
    hasAudio = !media.hasAudio
    lowerBound = target
    finalEnd = target
    preroll = true
    prerollSamples = 0
    prerollBackpressure = false
    prerollStarted = ProcessInfo.processInfo.systemUptime
    phase = .seeking
    publish(force: true)
    do {
      try decoder.seek(to: target)
      guard identity.accepts(request) else { return }
      output.setRate(0, at: CMTime(seconds: target, preferredTimescale: 1_000_000_000))
      // Yield even for an automatic A/B wrap. Tiny intervals or slow decoding
      // can cross B inside one pump; recursive seek -> pump would otherwise
      // grow the stack and delay subsequent stop/open requests indefinitely.
      schedulePump(after: .milliseconds(0))
    } catch { fail(error, revision: request) }
  }

  private func positionOnWorker() -> Double {
    if preroll { return lowerBound }
    let value = output.currentTime.seconds
    let result = value.isFinite ? max(lowerBound, value) : lowerBound
    if let loop { return min(loop.end, result) }
    if let duration = media?.duration, duration > 0 { return min(duration, result) }
    return result
  }

  private func publish(force: Bool = false) {
    let now = ProcessInfo.processInfo.systemUptime
    guard force || now - lastSnapshotTime >= 0.1 else { return }
    lastSnapshotTime = now
    let snapshot = snapshotOnWorker()
    DispatchQueue.main.async { [weak self] in
      guard let self, self.identity.accepts(snapshot.revision) else { return }
      self.mainPhase = snapshot.phase
      self.onSnapshot?(snapshot)
    }
  }

  private func snapshotOnWorker() -> NativePlaybackSnapshot {
    NativePlaybackSnapshot(generation: generation, revision: revision,
      phase: phase, position: phase == .idle || phase == .closed ? 0 : positionOnWorker(),
      duration: media?.duration ?? 0, volume: volume, rate: rate, media: media,
      videoSamples: videoSamples, audioSamples: audioSamples,
      hardwareVideoSamples: hardwareVideoSamples, videoToolboxSamples: videoToolboxSamples,
      queuedBytes: queuedBytes, failure: failure)
  }

  private func fail(_ error: Error, revision request: UInt64) {
    guard identity.accepts(request) else { return }
    scheduledPump &+= 1
    output.setRate(0)
    output.flush(removeImage: true)
    pending = nil
    decoder?.close()
    decoder = nil
    _ = identity.install(nil, revision: request)
    outstanding.removeAll(keepingCapacity: true)
    queuedBytes = 0
    phase = .failed
    preroll = false
    wantsPlayback = false
    if let typed = error as? NativePlaybackFailure { failure = typed }
    else {
      let nsError = error as NSError
      failure = .decoder(nsError.domain, nsError.code)
    }
    publish(force: true)
  }

  private func schedulePump(after delay: DispatchTimeInterval = .milliseconds(10)) {
    scheduledPump &+= 1
    let token = scheduledPump
    worker.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, token == self.scheduledPump else { return }
      self.pump()
    }
  }

  private func finishPrerollIfReady() -> Bool {
    guard preroll, prerollSamples > 0 else { return false }
    // Autoplay can continue pumping when audio arrives before a reordered
    // video frame. A paused seek cannot: declaring it ready on audio alone
    // stops the pump and leaves the preview blank. Wait for the first video
    // frame (or an actually drained input), never just the wall-time budget.
    guard wantsPlayback || hasVideo || eof else { return false }
    // A stream's presence does not guarantee a sample at this position. Audio
    // can start late or end before video. Briefly prime both tracks when
    // possible, then let their original PTS and the shared clock schedule the
    // available samples. Never fill an entire paused renderer waiting for a
    // nonexistent second stream, or shift delayed audio to the seek target.
    let elapsed = ProcessInfo.processInfo.systemUptime - prerollStarted
    guard (hasVideo && hasAudio) || eof || prerollBackpressure || elapsed >= 0.1 else { return false }
    // setRate(time:) anchors asynchronously. An old high clock during a
    // backwards seek must never free the new queue budget or trigger B/EOF.
    let clock = output.currentTime.seconds
    guard output.actualRate == 0, clock.isFinite, abs(clock - lowerBound) <= 0.001 else { return false }
    preroll = false
    phase = wantsPlayback ? .playing : .paused
    output.setRate(wantsPlayback ? rate : 0)
    publish(force: true)
    return true
  }

  private func pump() {
    guard identity.accepts(revision), let decoder, let media,
          phase != .failed, phase != .closed, phase != .idle else { return }
    do {
      let clock = positionOnWorker()
      outstanding.removeAll { item in
        guard item.end <= clock else { return false }
        queuedBytes -= item.bytes
        return true
      }
      if preroll && ProcessInfo.processInfo.systemUptime - prerollStarted > 10 {
        throw NativePlaybackFailure.bufferLimit
      }
      if let error = output.error { throw error }
      // Anchor before enqueueing, not only before starting playback. During
      // a backwards seek the old (asynchronous) clock can otherwise discard
      // the new first frame as late. Paused previews would then stay blank
      // even though the session has already marked both streams primed.
      if preroll {
        let anchored = output.currentTime.seconds
        guard output.actualRate == 0, anchored.isFinite,
              abs(anchored - lowerBound) <= 0.001 else {
          schedulePump()
          return
        }
      }
      if finishPrerollIfReady() && !wantsPlayback { return }
      if finishPlaybackIfNeeded() { return }
      var budget = 8
      if preroll && hasVideo && hasAudio { budget = 0 }
      while !eof && budget > 0 && identity.accepts(revision) {
        if finishPlaybackIfNeeded() { return }
        budget -= 1
        if pending == nil { pending = try decoder.readSample() }
        guard identity.accepts(revision) else { return }
        guard let decoded = pending else { eof = true; break }
        let isVideo = decoded.isVideo
        let upperBound = loop?.end ?? (media.duration > 0 ? media.duration : nil)
        let gated = try NativePlaybackSampleGate.clip(decoded.sampleBuffer, video: isVideo,
          start: lowerBound, end: upperBound)
        switch gated {
        case .beforeRange:
          pending = nil
          continue
        case .afterRange:
          if isVideo { videoBoundary = true } else { audioBoundary = true }
          pending = nil
          if (videoBoundary || !media.hasVideo) && (audioBoundary || !media.hasAudio) { eof = true }
          continue
        case .sample(let sample):
          let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
          // Rational timestamp addition avoids a Double rounding residue past
          // duration. That residue would be unreachable by our clamped clock
          // and keep a fully drained file playing forever at EOF.
          let end = try NativePlaybackSampleGate.end(of: sample, clippedAt: upperBound)
          guard end.isFinite, end >= pts else { throw NativePlaybackFailure.malformedSample }
          let bytes = CMSampleBufferGetImageBuffer(sample).map(CVPixelBufferGetDataSize)
            ?? CMSampleBufferGetTotalSampleSize(sample)
          guard bytes >= 0, bytes <= maximumQueuedBytes else { throw NativePlaybackFailure.bufferLimit }
          if !preroll && pts > clock + maximumLead { budget = 0; break }
          guard queuedBytes <= maximumQueuedBytes - bytes, output.isReady(video: isVideo) else {
            if preroll { prerollBackpressure = true }
            budget = 0
            break
          }
          do { try output.enqueue(sample, video: isVideo) }
          catch NativeSampleBufferOutput.OutputError.backpressure {
            if preroll { prerollBackpressure = true }
            budget = 0
            break
          }
          pending = nil
          queuedBytes += bytes
          outstanding.append((end, bytes))
          finalEnd = max(finalEnd, end)
          if preroll { prerollSamples += 1 }
          if isVideo {
            hasVideo = true
            videoSamples += 1
            if decoded.hardwareDecoded { hardwareVideoSamples += 1 }
            if decoded.videoToolboxDecoded { videoToolboxSamples += 1 }
          } else { hasAudio = true; audioSamples += 1 }
          sampleObserver?(NativePlaybackSampleObservation(generation: generation, revision: revision,
            video: isVideo, start: pts, end: end, hardwareDecoded: decoded.hardwareDecoded,
            videoToolboxDecoded: decoded.videoToolboxDecoded))
        }
        if preroll && hasVideo && hasAudio {
          if finishPrerollIfReady() && !wantsPlayback { return }
          if preroll { break }
        }
      }
      if eof && preroll && prerollSamples == 0 { throw NativePlaybackFailure.malformedSample }
      if finishPrerollIfReady() && !wantsPlayback { return }
      if finishPlaybackIfNeeded() { return }
      publish()
      if preroll || wantsPlayback { schedulePump() }
    } catch { fail(error, revision: revision) }
  }

  private func finishPlaybackIfNeeded() -> Bool {
    guard !preroll, wantsPlayback else { return false }
    let position = positionOnWorker()
    // B is a clock boundary, not a demux EOF condition. A shorter audio track
    // might never produce a packet at B. Waiting for both tracks to cross it
    // would decode the entire remaining file before wrapping the video.
    if let loop, position >= loop.end {
      seekOnWorker(to: loop.start, revision: revision)
      return true
    }
    guard loop == nil, eof, position >= finalEnd else { return false }
    if repeatFile {
      seekOnWorker(to: 0, revision: revision)
    } else {
      output.setRate(0)
      phase = .ended
      wantsPlayback = false
      publish(force: true)
    }
    return true
  }
}
