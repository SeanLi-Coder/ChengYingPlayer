import Foundation
import CoreMedia
import AudioToolbox

/// A half-open media interval. The decoder may preroll before its start, but
/// samples are clipped before entering either output queue.
struct NativePlaybackInterval: Equatable {
  let start: Double
  let end: Double

  init(start: Double, end: Double) throws {
    guard start.isFinite, end.isFinite, start >= 0, end > start else {
      throw NativePlaybackFailure.invalidRange
    }
    self.start = start
    self.end = end
  }

  func contains(_ time: Double) -> Bool { time >= start && time < end }
}

enum NativePlaybackFailure: Error, Equatable {
  case invalidRange
  case invalidTime
  case invalidRate
  case malformedSample
  case sampleCopyFailed(Int32)
  case bufferLimit
  case outputRecoveryLimit
  case cancelled
  case decoder(String, Int)
}

enum NativePlaybackGateResult {
  case sample(CMSampleBuffer)
  case beforeRange
  case afterRange
}

/// This gate operates on decoded data. PCM is trimmed at sample boundaries;
/// video keeps its pixels and only adjusts presentation timing at the edges.
enum NativePlaybackSampleGate {
  static func end(of sample: CMSampleBuffer, clippedAt upperBound: Double?) throws -> Double {
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    let duration = CMSampleBufferGetDuration(sample)
    let last = CMTimeAdd(pts, duration)
    guard pts.isNumeric, duration.isNumeric, last.isNumeric, last.seconds.isFinite,
          duration.seconds >= 0,
          upperBound.map({ $0.isFinite && $0 >= pts.seconds }) ?? true else {
      throw NativePlaybackFailure.malformedSample
    }
    return min(last.seconds, upperBound ?? last.seconds)
  }

  static func clip(_ sample: CMSampleBuffer, video: Bool, start: Double,
                   end: Double?) throws -> NativePlaybackGateResult {
    guard start.isFinite, start >= 0,
          end.map({ $0.isFinite && $0 > start }) ?? true else {
      throw NativePlaybackFailure.invalidRange
    }
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
    guard timestamp.isNumeric, timestamp.seconds.isFinite else {
      throw NativePlaybackFailure.malformedSample
    }
    let pts = timestamp.seconds
    if let end, pts >= end { return .afterRange }
    if video {
      let duration = CMSampleBufferGetDuration(sample)
      guard duration.isNumeric, duration.seconds > 0, duration.seconds.isFinite,
            CMSampleBufferGetImageBuffer(sample) != nil else {
        throw NativePlaybackFailure.malformedSample
      }
      let last = pts + duration.seconds
      guard last.isFinite else { throw NativePlaybackFailure.malformedSample }
      if last <= start { return .beforeRange }
      let clippedStart = max(pts, start)
      let clippedEnd = min(last, end ?? last)
      guard clippedEnd > clippedStart else { return .beforeRange }
      if clippedStart == pts && clippedEnd == last { return .sample(sample) }
      var timing = CMSampleTimingInfo(
        duration: CMTime(seconds: clippedEnd - clippedStart, preferredTimescale: 1_000_000_000),
        presentationTimeStamp: CMTime(seconds: clippedStart, preferredTimescale: 1_000_000_000),
        decodeTimeStamp: .invalid)
      var copy: CMSampleBuffer?
      let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
        sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleBufferOut: &copy)
      guard status == noErr, let copy else { throw NativePlaybackFailure.sampleCopyFailed(status) }
      return .sample(copy)
    }

    guard let format = CMSampleBufferGetFormatDescription(sample),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
          asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate.isFinite,
          asbd.mSampleRate > 0, asbd.mSampleRate <= 768_000 else {
      throw NativePlaybackFailure.malformedSample
    }
    let count = CMSampleBufferGetNumSamples(sample)
    guard count > 0 else { throw NativePlaybackFailure.malformedSample }
    // Clamp in Double before converting to Int, including a seek far beyond
    // this buffer. Never permit a malformed timestamp to overflow a conversion.
    // Work in absolute sample coordinates before subtracting. Subtracting
    // large Double seconds first loses a sample at e.g. 9000 s / 192 kHz.
    // Tolerance is the rounding uncertainty of the actual operands, not a
    // fixed media-time epsilon that grows into an audible range violation.
    let origin = Double(timestamp.value) * (asbd.mSampleRate / Double(timestamp.timescale))
    func offset(_ seconds: Double, roundingUp: Bool) throws -> Double {
      let boundary = seconds * asbd.mSampleRate
      guard boundary.isFinite, origin.isFinite else { throw NativePlaybackFailure.invalidTime }
      let uncertainty = 4 * max(boundary.ulp, origin.ulp)
      guard uncertainty < 0.001 else { throw NativePlaybackFailure.invalidTime }
      let distance = boundary - origin
      return roundingUp ? ceil(distance - uncertainty) : floor(distance + uncertainty)
    }
    let firstOffset = try offset(start, roundingUp: true)
    let finalOffset = try end.map { try offset($0, roundingUp: false) } ?? Double(count)
    let first = Int(min(Double(count), max(0, firstOffset)))
    let final = Int(min(Double(count), max(0, finalOffset)))
    if first >= count { return .beforeRange }
    if final <= first { return .afterRange }
    if first == 0 && final == count { return .sample(sample) }
    var copy: CMSampleBuffer?
    let status = CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault,
      sampleBuffer: sample, sampleRange: CFRange(location: first, length: final - first),
      sampleBufferOut: &copy)
    guard status == noErr, let copy else { throw NativePlaybackFailure.sampleCopyFailed(status) }
    return .sample(copy)
  }
}
