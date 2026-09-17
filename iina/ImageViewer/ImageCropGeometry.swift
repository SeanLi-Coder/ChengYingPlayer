import Cocoa

/// Crop coordinates describe pixel edges, with the origin at the source image's top-left.
enum ImageCropGeometry {
  enum Handle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var horizontal: Int {
      switch self {
      case .topLeft, .bottomLeft, .left: return -1
      case .topRight, .bottomRight, .right: return 1
      default: return 0
      }
    }

    var vertical: Int {
      switch self {
      case .topLeft, .topRight, .top: return -1
      case .bottomLeft, .bottomRight, .bottom: return 1
      default: return 0
      }
    }
  }

  static func validAspect(_ aspect: CGFloat?) -> CGFloat? {
    guard let aspect, aspect.isFinite, aspect > 0 else { return nil }
    return aspect
  }

  static func sanitize(_ rect: ImagePixelRect?, width: Int, height: Int) -> ImagePixelRect? {
    guard let rect, width > 0, height > 0, rect.width > 0, rect.height > 0 else { return nil }
    let x = min(max(rect.x, 0), width - 1)
    let y = min(max(rect.y, 0), height - 1)
    return ImagePixelRect(x: x, y: y, width: min(rect.width, width - x), height: min(rect.height, height - y))
  }

  static func largest(width: Int, height: Int, aspect: CGFloat?) -> ImagePixelRect? {
    guard width > 0, height > 0 else { return nil }
    guard let aspect = boundedAspect(aspect, width: width, height: height) else {
      return ImagePixelRect(x: 0, y: 0, width: width, height: height)
    }
    let w = min(CGFloat(width), CGFloat(height) * aspect)
    let h = w / aspect
    let iw = integer(w, maximum: width), ih = integer(h, maximum: height)
    return ImagePixelRect(x: (width - iw) / 2, y: (height - ih) / 2, width: iw, height: ih)
  }

  static func sourcePoint(_ point: CGPoint, imageRect: CGRect, width: Int, height: Int) -> CGPoint? {
    guard finite(point), validViewRect(imageRect), width > 0, height > 0 else { return nil }
    let x = (point.x - imageRect.minX) / imageRect.width * CGFloat(width)
    let y = (imageRect.maxY - point.y) / imageRect.height * CGFloat(height)
    guard x.isFinite, y.isFinite else { return nil }
    return CGPoint(x: min(max(x, 0), CGFloat(width)), y: min(max(y, 0), CGFloat(height)))
  }

  static func viewRect(_ selection: ImagePixelRect, imageRect: CGRect, width: Int, height: Int) -> CGRect {
    guard let rect = sanitize(selection, width: width, height: height), validViewRect(imageRect) else { return .zero }
    let sx = imageRect.width / CGFloat(width), sy = imageRect.height / CGFloat(height)
    return CGRect(x: imageRect.minX + CGFloat(rect.x) * sx,
                  y: imageRect.maxY - CGFloat(rect.y + rect.height) * sy,
                  width: CGFloat(rect.width) * sx, height: CGFloat(rect.height) * sy)
  }

  static func create(from start: CGPoint, to end: CGPoint, width: Int, height: Int,
                     aspect: CGFloat?) -> ImagePixelRect? {
    guard width > 0, height > 0, finite(start), finite(end) else { return nil }
    let start = bounded(start, width: width, height: height)
    let end = bounded(end, width: width, height: height)
    let dx: CGFloat = end.x >= start.x ? 1 : -1
    let dy: CGFloat = end.y >= start.y ? 1 : -1
    let anchor = CGPoint(x: dx < 0 ? max(start.x, 1) : min(start.x, CGFloat(width - 1)),
                         y: dy < 0 ? max(start.y, 1) : min(start.y, CGFloat(height - 1)))
    return anchored(anchor: anchor, dx: dx, dy: dy, proposedWidth: abs(end.x - start.x),
                    proposedHeight: abs(end.y - start.y), width: width, height: height, aspect: aspect)
  }

  static func move(_ selection: ImagePixelRect, delta: CGPoint, width: Int, height: Int) -> ImagePixelRect? {
    guard let rect = sanitize(selection, width: width, height: height), finite(delta) else { return nil }
    let x = min(max(CGFloat(rect.x) + delta.x, 0), CGFloat(width - rect.width))
    let y = min(max(CGFloat(rect.y) + delta.y, 0), CGFloat(height - rect.height))
    guard x.isFinite, y.isFinite else { return nil }
    return ImagePixelRect(x: nonnegativeInteger(x, maximum: width - rect.width),
                          y: nonnegativeInteger(y, maximum: height - rect.height), width: rect.width, height: rect.height)
  }

  static func resize(_ selection: ImagePixelRect, handle: Handle, to point: CGPoint,
                     width: Int, height: Int, aspect: CGFloat?) -> ImagePixelRect? {
    guard let rect = sanitize(selection, width: width, height: height), finite(point) else { return nil }
    let point = bounded(point, width: width, height: height)
    let dx = CGFloat(handle.horizontal), dy = CGFloat(handle.vertical)
    let anchor = CGPoint(x: dx < 0 ? CGFloat(rect.x + rect.width) : dx > 0 ? CGFloat(rect.x) : CGFloat(rect.x) + CGFloat(rect.width) / 2,
                         y: dy < 0 ? CGFloat(rect.y + rect.height) : dy > 0 ? CGFloat(rect.y) : CGFloat(rect.y) + CGFloat(rect.height) / 2)
    let proposedWidth = dx == 0 ? CGFloat(rect.width) : max(1, (point.x - anchor.x) * dx)
    let proposedHeight = dy == 0 ? CGFloat(rect.height) : max(1, (point.y - anchor.y) * dy)
    return anchored(anchor: anchor, dx: dx, dy: dy, proposedWidth: proposedWidth,
                    proposedHeight: proposedHeight, width: width, height: height, aspect: aspect)
  }

  private static func anchored(anchor: CGPoint, dx: CGFloat, dy: CGFloat, proposedWidth: CGFloat,
                               proposedHeight: CGFloat, width: Int, height: Int, aspect: CGFloat?) -> ImagePixelRect {
    let maxWidth = dx < 0 ? anchor.x : dx > 0 ? CGFloat(width) - anchor.x : 2 * min(anchor.x, CGFloat(width) - anchor.x)
    let maxHeight = dy < 0 ? anchor.y : dy > 0 ? CGFloat(height) - anchor.y : 2 * min(anchor.y, CGFloat(height) - anchor.y)
    var w = max(1, min(proposedWidth, maxWidth)), h = max(1, min(proposedHeight, maxHeight))
    if let ratio = boundedAspect(aspect, width: width, height: height) {
      let requested = dx == 0 ? proposedHeight * ratio : dy == 0 ? proposedWidth : max(proposedWidth, proposedHeight * ratio)
      w = max(1, min(requested, maxWidth, maxHeight * ratio))
      h = max(1, w / ratio)
    }
    let iw = integer(w, maximum: width), ih = integer(h, maximum: height)
    let x = dx < 0 ? anchor.x - CGFloat(iw) : dx > 0 ? anchor.x : anchor.x - CGFloat(iw) / 2
    let y = dy < 0 ? anchor.y - CGFloat(ih) : dy > 0 ? anchor.y : anchor.y - CGFloat(ih) / 2
    return ImagePixelRect(x: nonnegativeInteger(x, maximum: width - iw),
                          y: nonnegativeInteger(y, maximum: height - ih), width: iw, height: ih)
  }

  private static func boundedAspect(_ aspect: CGFloat?, width: Int, height: Int) -> CGFloat? {
    guard let aspect = validAspect(aspect) else { return nil }
    // Extreme ratios cannot be represented more accurately than a single source pixel.
    return min(max(aspect, 1 / CGFloat(height)), CGFloat(width))
  }

  private static func integer(_ value: CGFloat, maximum: Int) -> Int {
    max(1, nonnegativeInteger(value, maximum: maximum))
  }

  private static func nonnegativeInteger(_ value: CGFloat, maximum: Int) -> Int {
    let rounded = max(value.rounded(), 0)
    // CGFloat(Int.max) rounds up on 64-bit platforms and cannot be converted directly back to Int.
    return rounded >= CGFloat(maximum) ? maximum : Int(rounded)
  }

  private static func bounded(_ point: CGPoint, width: Int, height: Int) -> CGPoint {
    CGPoint(x: min(max(point.x, 0), CGFloat(width)), y: min(max(point.y, 0), CGFloat(height)))
  }

  private static func finite(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }

  private static func validViewRect(_ rect: CGRect) -> Bool {
    rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
  }
}
