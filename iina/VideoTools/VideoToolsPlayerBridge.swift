//
//  VideoToolsPlayerBridge.swift
//  ChengYing
//

import Foundation

/// A viewing transform relative to mpv's normal fitted video rectangle, not the window.
struct VideoToolsViewport: Equatable {
  let scale: Double
  let panX: Double
  let panY: Double

  var zoom: Double { log2(scale) }

  init(zoom: Double, panX: Double, panY: Double) {
    let zoom = zoom.isFinite ? min(3, max(log2(0.2), zoom)) : 0
    self.init(scale: pow(2, zoom), panX: panX, panY: panY)
  }

  private init(scale: Double, panX: Double, panY: Double) {
    self.scale = min(8, max(0.2, scale))
    // Keep the original fitted rectangle covered when zoomed. Returning to the
    // normal view recenters it, so a pan cannot leave the picture off-screen.
    let limit = max(0, (1 - 1 / self.scale) / 2)
    self.panX = panX.isFinite ? min(limit, max(-limit, panX)) : 0
    self.panY = panY.isFinite ? min(limit, max(-limit, panY)) : 0
  }

  func applying(_ action: VideoToolsShortcuts.Action) -> VideoToolsViewport? {
    switch action {
    case .zoomIn, .zoomOut:
      let delta = action == .zoomIn ? 0.1 : -0.1
      // Preserve arbitrary imported scales while removing binary rounding noise.
      let next = ((scale + delta) * 1_000_000_000_000).rounded() / 1_000_000_000_000
      return VideoToolsViewport(scale: next, panX: panX, panY: panY)
    case .panLeft, .panRight, .panUp, .panDown:
      // mpv's pan unit is the full scaled image size. Compensate for zoom so
      // each press moves by 5% of the original fitted dimension at every scale.
      let step = 0.05 / scale
      return VideoToolsViewport(scale: scale,
        panX: panX + (action == .panLeft ? -step : action == .panRight ? step : 0),
        panY: panY + (action == .panUp ? -step : action == .panDown ? step : 0))
    case .resetViewport:
      return VideoToolsViewport(scale: 1, panX: 0, panY: 0)
    default:
      return nil
    }
  }
}

struct VideoToolsPlayerSnapshot {
  let mediaURL: URL
  let mediaGeneration: UInt64
  let position: Double
  let wasPaused: Bool
  let abLoopA: Double
  let abLoopB: Double
  let abLoopCount: String
  let rotation: Int
  var abLoopAOption: String? = nil
  var abLoopBOption: String? = nil
}

extension PlayerCore {
  @discardableResult
  func videoToolsApplyViewportShortcut(_ action: VideoToolsShortcuts.Action) -> VideoToolsViewport? {
    guard info.state.loaded, let videoTrack = info.vid, videoTrack > 0 else { return nil }
    let current = VideoToolsViewport(zoom: mpv.getDouble(MPVOption.Video.videoZoom),
      panX: mpv.getDouble(MPVOption.Video.videoPanX), panY: mpv.getDouble(MPVOption.Video.videoPanY))
    guard let next = current.applying(action) else { return nil }
    // Only presentation properties change. Do not resize a window, seek, change
    // playback speed, or affect the source used by any export operation.
    mpv.setDouble(MPVOption.Video.videoZoom, next.zoom)
    mpv.setDouble(MPVOption.Video.videoPanX, next.panX)
    mpv.setDouble(MPVOption.Video.videoPanY, next.panY)
    return next
  }

  func videoToolsResetViewport() {
    guard info.state.loaded else { return }
    mpv.setDouble(MPVOption.Video.videoZoom, 0)
    mpv.setDouble(MPVOption.Video.videoPanX, 0)
    mpv.setDouble(MPVOption.Video.videoPanY, 0)
  }

  var videoToolsLoopRange: VideoToolsLoopRange? {
    guard info.state.loaded,
          let count = mpv.getString(MPVOption.PlaybackControl.abLoopCount), count != "0" else { return nil }
    return VideoToolsLoopRange(
      start: videoToolsLoopMarker(MPVOption.PlaybackControl.abLoopA),
      end: videoToolsLoopMarker(MPVOption.PlaybackControl.abLoopB),
      duration: info.videoDuration?.second
    )
  }

  private func videoToolsLoopMarker(_ property: String) -> Double? {
    // The string form distinguishes an unset marker from zero, but rounds numeric
    // timestamps. Read the double separately so an EOF marker cannot exceed duration.
    guard VideoToolsLoopRange.marker(from: mpv.getString(property)) != nil else { return nil }
    let value = mpv.getDouble(property)
    return value.isFinite && value >= 0 ? value : nil
  }

  /// Replacing A also clears B so an old endpoint never silently starts a new loop.
  @discardableResult
  func videoToolsSetLoopStart() -> Bool {
    guard let position = videoToolsCurrentTime else { return false }
    if let duration = info.videoDuration?.second, position >= duration { return false }
    videoToolsClearLoop()
    mpv.setDouble(MPVOption.PlaybackControl.abLoopA, position)
    syncAbLoop()
    return true
  }

  @discardableResult
  func videoToolsSetLoopEnd() -> Bool {
    guard let position = videoToolsCurrentTime,
          let range = VideoToolsLoopRange(
            start: videoToolsLoopMarker(MPVOption.PlaybackControl.abLoopA),
            end: position, duration: info.videoDuration?.second) else { return false }
    videoToolsActivateLoop(range)
    seek(absoluteSecond: range.start)
    return true
  }

  func videoToolsClearLoop() {
    videoToolsLoopRecovery.reset()
    guard info.state != .shuttingDown, info.state != .shutDown else { return }
    mpv.setString(MPVOption.PlaybackControl.abLoopCount, "0")
    mpv.setString(MPVOption.PlaybackControl.abLoopA, "no")
    mpv.setString(MPVOption.PlaybackControl.abLoopB, "no")
    syncAbLoop()
  }

  private func videoToolsActivateLoop(_ range: VideoToolsLoopRange) {
    videoToolsLoopRecovery.reset()
    mpv.setString(MPVOption.PlaybackControl.abLoopCount, "0")
    mpv.setDouble(MPVOption.PlaybackControl.abLoopA, range.start)
    mpv.setDouble(MPVOption.PlaybackControl.abLoopB, range.end)
    mpv.setString(MPVOption.PlaybackControl.abLoopCount, "inf")
    syncAbLoop()
  }

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
      shouldPause = shouldPause || (videoToolsLoopRange == nil && target >= lastPosition)
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
      rotation: mpv.getInt(MPVOption.Video.videoRotate),
      abLoopAOption: mpv.getString(MPVOption.PlaybackControl.abLoopA),
      abLoopBOption: mpv.getString(MPVOption.PlaybackControl.abLoopB)
    )
  }

  func videoToolsPreviewRange(start: Double, end: Double) {
    guard info.state.loaded,
          let range = VideoToolsLoopRange(start: start, end: end, duration: info.videoDuration?.second) else { return }
    videoToolsActivateLoop(range)
    seek(absoluteSecond: start)
    resume()
  }

  func videoToolsPreviewRotation(_ degrees: Int) {
    guard info.state.loaded, [0, 90, 180, 270, 360].contains(degrees) else { return }
    let rotation = degrees == 360 ? 0 : degrees
    // Export progress republishes the same angle; only actual changes need a write.
    guard mpv.getInt(MPVOption.Video.videoRotate) != rotation else { return }
    mpv.setInt(MPVOption.Video.videoRotate, rotation)
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
    videoToolsLoopRecovery.reset()
    mpv.setString(MPVOption.PlaybackControl.abLoopCount, "0")
    videoToolsRestoreLoopMarker(MPVOption.PlaybackControl.abLoopA, value: snapshot.abLoopA, option: snapshot.abLoopAOption)
    videoToolsRestoreLoopMarker(MPVOption.PlaybackControl.abLoopB, value: snapshot.abLoopB, option: snapshot.abLoopBOption)
    mpv.setString(MPVOption.PlaybackControl.abLoopCount, snapshot.abLoopCount)
    syncAbLoop()
    mpv.setInt(MPVOption.Video.videoRotate, snapshot.rotation)
  }

  private func videoToolsRestoreLoopMarker(_ property: String, value: Double, option: String?) {
    let isSet = VideoToolsLoopRange.marker(from: option) != nil || (option == nil && value > 0)
    if isSet, value.isFinite, value >= 0 {
      mpv.setDouble(property, value)
    } else {
      mpv.setString(property, "no")
    }
  }
}
