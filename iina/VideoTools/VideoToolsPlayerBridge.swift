//
//  VideoToolsPlayerBridge.swift
//  ChengYing
//

import Foundation

struct VideoToolsPlayerSnapshot {
  let mediaURL: URL
  let mediaGeneration: UInt64
  let position: Double
  let wasPaused: Bool
  let abLoopA: Double
  let abLoopB: Double
  let abLoopCount: String
  let rotation: Int
}

extension PlayerCore {
  /// Read mpv directly so a marker does not use the UI timer's cached position.
  var videoToolsCurrentTime: Double? {
    guard info.state.loaded else { return nil }
    let position = mpv.getFlag(MPVProperty.eofReached)
      ? info.videoDuration?.second ?? 0
      : mpv.getDouble(MPVProperty.timePos)
    guard position.isFinite, position >= 0 else { return nil }
    return position
  }

  /// Keep navigation inside the current file, including at the end boundary.
  func videoToolsSeek(to seconds: Double, pausePlayback: Bool) {
    guard info.state.loaded, seconds.isFinite else { return }
    var target = max(0, seconds)
    var shouldPause = pausePlayback
    if let duration = info.videoDuration?.second, duration.isFinite, duration > 0 {
      let lastPosition = max(0, duration - 0.001)
      shouldPause = shouldPause || target >= lastPosition
      target = min(target, lastPosition)
    }
    if shouldPause { pause() }
    seek(absoluteSecond: target)
  }

  func videoToolsCaptureSnapshot() -> VideoToolsPlayerSnapshot? {
    guard info.state.loaded, let mediaURL = info.currentURL,
          let position = videoToolsCurrentTime else { return nil }
    return VideoToolsPlayerSnapshot(
      mediaURL: mediaURL,
      mediaGeneration: videoToolsMediaGeneration,
      position: position,
      wasPaused: mpv.getFlag(MPVOption.PlaybackControl.pause),
      abLoopA: mpv.getDouble(MPVOption.PlaybackControl.abLoopA),
      abLoopB: mpv.getDouble(MPVOption.PlaybackControl.abLoopB),
      abLoopCount: mpv.getString(MPVOption.PlaybackControl.abLoopCount) ?? "0",
      rotation: mpv.getInt(MPVOption.Video.videoRotate)
    )
  }

  func videoToolsPreviewRange(start: Double, end: Double) {
    guard info.state.loaded else { return }
    mpv.setString(MPVOption.PlaybackControl.abLoopCount, "0")
    mpv.setDouble(MPVOption.PlaybackControl.abLoopA, max(0.000001, start))
    mpv.setDouble(MPVOption.PlaybackControl.abLoopB, max(0.000001, end))
    mpv.setString(MPVOption.PlaybackControl.abLoopCount, "inf")
    syncAbLoop()
    seek(absoluteSecond: start)
    resume()
  }

  func videoToolsPreviewRotation(_ degrees: Int) {
    guard info.state.loaded else { return }
    mpv.setInt(MPVOption.Video.videoRotate, degrees == 360 ? 0 : degrees)
  }

  /// Restore only state changed by preview before mpv unloads the current file.
  /// The current URL may already point at the incoming file, so this deliberately
  /// does not inspect the URL or seek to the saved position.
  func videoToolsRestorePreviewBeforeUnload(_ snapshot: VideoToolsPlayerSnapshot) {
    let state = info.state
    guard state != .shuttingDown, state != .shutDown else { return }
    if state.loaded, snapshot.wasPaused {
      pause()
    }
    videoToolsRestorePreviewOptions(snapshot)
  }

  func videoToolsRestoreSnapshot(_ snapshot: VideoToolsPlayerSnapshot, restorePlaybackState: Bool = true) {
    let state = info.state
    guard state != .shuttingDown, state != .shutDown else { return }
    guard videoToolsMediaGeneration == snapshot.mediaGeneration,
          info.currentURL == snapshot.mediaURL || info.currentURL == nil else { return }
    let canRestorePlaybackPosition = state.loaded && restorePlaybackState
    if canRestorePlaybackPosition, snapshot.wasPaused {
      pause()
    }
    videoToolsRestorePreviewOptions(snapshot)
    if canRestorePlaybackPosition {
      seek(absoluteSecond: snapshot.position)
      if !snapshot.wasPaused {
        resume()
      }
    }
  }

  private func videoToolsRestorePreviewOptions(_ snapshot: VideoToolsPlayerSnapshot) {
    mpv.setString(MPVOption.PlaybackControl.abLoopCount, "0")
    mpv.setDouble(MPVOption.PlaybackControl.abLoopA, snapshot.abLoopA)
    mpv.setDouble(MPVOption.PlaybackControl.abLoopB, snapshot.abLoopB)
    mpv.setString(MPVOption.PlaybackControl.abLoopCount, snapshot.abLoopCount)
    syncAbLoop()
    mpv.setInt(MPVOption.Video.videoRotate, snapshot.rotation)
  }
}
