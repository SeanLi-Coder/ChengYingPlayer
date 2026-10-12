import AppKit
import AVFoundation

/// Main-thread presentation only. This view neither owns the playback clock nor
/// sends renderer/decoder commands. Attach on main after constructing the output,
/// and detach before retiring its session. Positive pan Y means up in view points.
final class NativePlaybackSurface: NSView {
  struct VideoGeometry: Equatable {
    let codedSize: CGSize
    let pixelAspectRatio: Double
    /// Clockwise source rotation, matching CYNMediaInfo.rotationDegrees.
    let rotationDegrees: Int

    var unrotatedDisplaySize: CGSize {
      CGSize(width: codedSize.width * pixelAspectRatio, height: codedSize.height)
    }
  }

  private struct LayerState {
    let bounds: CGRect
    let position: CGPoint
    let anchorPoint: CGPoint
    let transform: CATransform3D
    let gravity: AVLayerVideoGravity
    let contentsScale: CGFloat
    let hidden: Bool
  }

  private(set) var displayLayer: AVSampleBufferDisplayLayer?
  private(set) var geometry: VideoGeometry?
  private(set) var zoom: Double = 1
  private(set) var pan: CGPoint = .zero
  private var normalizedPan: CGPoint?
  /// The unclipped video rectangle in this view's unflipped point coordinates.
  private(set) var displayedVideoRect: CGRect?
  private var originalLayerState: LayerState?

  override var isFlipped: Bool { false }

  /// Existing player controls retain mouse/gesture ownership when this view is
  /// embedded above their video view. This is a display surface, not a control.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override init(frame frameRect: NSRect) {
    dispatchPrecondition(condition: .onQueue(.main))
    super.init(frame: frameRect)
    wantsLayer = true
  }

  required init?(coder: NSCoder) {
    dispatchPrecondition(condition: .onQueue(.main))
    super.init(coder: coder)
    wantsLayer = true
  }

  override func makeBackingLayer() -> CALayer {
    let result = CALayer()
    result.backgroundColor = NSColor.black.cgColor
    result.masksToBounds = true
    return result
  }

  /// A layer already attached elsewhere is rejected, not stolen from another
  /// window. Replace a session with an explicit detach followed by attach.
  @discardableResult
  func attach(_ candidate: AVSampleBufferDisplayLayer) -> Bool {
    requireMain()
    if let displayLayer { return displayLayer === candidate && candidate.superlayer === layer }
    guard candidate.superlayer == nil, let host = layer else { return false }
    originalLayerState = LayerState(bounds: candidate.bounds, position: candidate.position,
      anchorPoint: candidate.anchorPoint, transform: candidate.transform,
      gravity: candidate.videoGravity, contentsScale: candidate.contentsScale,
      hidden: candidate.isHidden)
    displayLayer = candidate
    withoutAnimations {
      candidate.anchorPoint = CGPoint(x: 0.5, y: 0.5)
      // SAR and rotation are applied exactly once by this surface. The renderer
      // must not introduce another aspect-fit inside the computed video bounds.
      candidate.videoGravity = .resize
      host.addSublayer(candidate)
      updateVideoLayout()
    }
    return true
  }

  /// Does not flush, stop or shut down the output. Its owner handles those
  /// operations on the worker; only layer ownership is changed here.
  @discardableResult
  func detach() -> AVSampleBufferDisplayLayer? {
    requireMain()
    guard let detached = displayLayer else { return nil }
    withoutAnimations {
      detached.removeFromSuperlayer()
      if let original = originalLayerState {
        detached.bounds = original.bounds
        detached.position = original.position
        detached.anchorPoint = original.anchorPoint
        detached.transform = original.transform
        detached.videoGravity = original.gravity
        detached.contentsScale = original.contentsScale
        detached.isHidden = original.hidden
      }
    }
    displayLayer = nil
    originalLayerState = nil
    displayedVideoRect = nil
    return detached
  }

  /// Invalid input leaves the last valid geometry unchanged. Unsupported source
  /// geometry is a caller-visible failure, never a silent crop or aspect guess.
  @discardableResult
  func setVideoGeometry(codedSize: CGSize, pixelAspectRatio: Double = 1,
                        rotationDegrees: Int = 0) -> Bool {
    requireMain()
    guard codedSize.width.isFinite, codedSize.height.isFinite,
          codedSize.width >= 1, codedSize.height >= 1,
          codedSize.width <= 32768, codedSize.height <= 32768,
          codedSize.width.rounded(.towardZero) == codedSize.width,
          codedSize.height.rounded(.towardZero) == codedSize.height,
          codedSize.width * codedSize.height <= 268_435_456,
          pixelAspectRatio.isFinite, (1.0 / 256...256).contains(pixelAspectRatio),
          rotationDegrees % 90 == 0 else { return false }
    geometry = VideoGeometry(codedSize: codedSize, pixelAspectRatio: pixelAspectRatio,
      rotationDegrees: ((rotationDegrees % 360) + 360) % 360)
    updateVideoLayout()
    return true
  }

  func clearVideoGeometry() {
    requireMain()
    geometry = nil
    updateVideoLayout()
  }

  /// Zoom is a linear factor relative to aspect-fit, not a logarithmic mpv zoom.
  /// Pan is a point offset from viewport center, not a fraction of image size.
  @discardableResult
  func setViewport(zoom: Double = 1, pan: CGPoint = .zero) -> Bool {
    requireMain()
    guard zoom.isFinite, (0.05...32).contains(zoom),
          pan.x.isFinite, pan.y.isFinite,
          abs(pan.x) <= 1_048_576, abs(pan.y) <= 1_048_576 else { return false }
    self.zoom = zoom
    self.pan = pan
    normalizedPan = nil
    updateVideoLayout()
    return true
  }

  /// Pan follows the shared controls: fractions of the rotated, scaled image,
  /// with positive Y down. Keep the fractions so resize preserves their meaning.
  @discardableResult
  func setNormalizedViewport(zoom: Double, pan: CGPoint) -> Bool {
    requireMain()
    guard zoom.isFinite, (0.05...32).contains(zoom),
          pan.x.isFinite, pan.y.isFinite,
          abs(pan.x) <= 0.5, abs(pan.y) <= 0.5 else { return false }
    self.zoom = zoom
    normalizedPan = pan
    updateVideoLayout()
    return true
  }

  func resetViewport() {
    requireMain()
    _ = setViewport()
  }

  override func layout() {
    super.layout()
    updateVideoLayout()
  }

  override func setFrameSize(_ newSize: NSSize) {
    requireMain()
    guard Self.validViewportSize(newSize) else { return }
    super.setFrameSize(newSize)
    updateVideoLayout()
  }

  override func setBoundsSize(_ newSize: NSSize) {
    requireMain()
    guard Self.validViewportSize(newSize) else { return }
    super.setBoundsSize(newSize)
    updateVideoLayout()
  }

  override func setBoundsOrigin(_ newOrigin: NSPoint) {
    requireMain()
    guard newOrigin.x.isFinite, newOrigin.y.isFinite,
          abs(newOrigin.x) <= 1_048_576, abs(newOrigin.y) <= 1_048_576 else { return }
    super.setBoundsOrigin(newOrigin)
    updateVideoLayout()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateVideoLayout()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateVideoLayout()
  }

  override var isHidden: Bool {
    didSet { updateVideoLayout() }
  }

  private func updateVideoLayout() {
    requireMain()
    guard let video = displayLayer, let host = layer else { return }
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    withoutAnimations {
      host.contentsScale = scale.isFinite && (1...8).contains(scale) ? scale : 1
      video.contentsScale = host.contentsScale
      host.masksToBounds = true
      guard let geometry, bounds.width.isFinite, bounds.height.isFinite,
            bounds.minX.isFinite, bounds.minY.isFinite,
            bounds.width > 0, bounds.height > 0,
            bounds.width <= 65536, bounds.height <= 65536,
            abs(bounds.minX) <= 1_048_576, abs(bounds.minY) <= 1_048_576 else {
        displayedVideoRect = nil
        video.isHidden = true
        video.bounds = .zero
        video.position = .zero
        video.transform = CATransform3DIdentity
        return
      }
      let size = geometry.unrotatedDisplaySize
      let quarterTurn = geometry.rotationDegrees == 90 || geometry.rotationDegrees == 270
      let rotated = quarterTurn ? CGSize(width: size.height, height: size.width) : size
      let fit = min(bounds.width / rotated.width, bounds.height / rotated.height) * zoom
      let width = size.width * fit, height = size.height * fit
      let rotatedSize = quarterTurn ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
      if let normalizedPan {
        pan = CGPoint(x: rotatedSize.width * normalizedPan.x, y: -rotatedSize.height * normalizedPan.y)
      }
      let center = CGPoint(x: bounds.midX + pan.x, y: bounds.midY + pan.y)
      // Exact quarter-turn matrices avoid trigonometric residue and define
      // clockwise rotation explicitly in AppKit's upward-positive coordinates.
      let rotation: CGAffineTransform
      switch geometry.rotationDegrees {
      case 90: rotation = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
      case 180: rotation = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
      case 270: rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
      default: rotation = .identity
      }
      video.bounds = CGRect(x: 0, y: 0, width: width, height: height)
      video.position = center
      video.transform = CATransform3DMakeAffineTransform(rotation)
      displayedVideoRect = CGRect(x: center.x - rotatedSize.width / 2,
        y: center.y - rotatedSize.height / 2, width: rotatedSize.width, height: rotatedSize.height)
      video.isHidden = isHidden
    }
  }

  private func withoutAnimations(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
  }

  private func requireMain() {
    dispatchPrecondition(condition: .onQueue(.main))
  }

  private static func validViewportSize(_ size: CGSize) -> Bool {
    size.width.isFinite && size.height.isFinite && size.width >= 0 && size.height >= 0 &&
      size.width <= 65536 && size.height <= 65536
  }
}
