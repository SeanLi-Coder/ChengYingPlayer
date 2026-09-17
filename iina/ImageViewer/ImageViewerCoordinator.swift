import Cocoa

/// Separate images from playback inputs without changing explicit video selection order.
struct ImageOpenPlan {
  let imageURLs: [URL]
  let mediaURLs: [URL]
  var imageCount: Int { imageURLs.count }

  static func make(_ urls: [URL], playbackExtensions: Set<String>) -> ImageOpenPlan {
    var images: [URL] = []
    var media: [URL] = []
    var seen = Set<URL>()
    func appendImage(_ url: URL) {
      let identity = url.standardizedFileURL.resolvingSymlinksInPath()
      if seen.insert(identity).inserted { images.append(url) }
    }
    for url in urls {
      guard url.isFileURL else { media.append(url); continue }
      if PlaylistPlaybackPolicy.isDirectory(url) {
        // Disc menus belong to mpv even when a disc contains cover artwork.
        let discFolders = [url, url.appendingPathComponent("BDMV", isDirectory: true)]
        let isDisc = discFolders.contains { directory in
          let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
          return names.contains("MovieObject.bdmv") && names.contains("index.bdmv")
        }
        if isDisc { media.append(url); continue }
        let files = PlaylistPlaybackPolicy.regularFiles(in: url)
        let imageFiles = files.filter(ImageFileSupport.isImageURL)
        imageFiles.forEach(appendImage)
        if imageFiles.isEmpty || files.contains(where: { playbackExtensions.contains($0.pathExtension.lowercased()) }) {
          media.append(url)
        }
      } else if ImageFileSupport.isImageURL(url) {
        appendImage(url)
      } else {
        media.append(url)
      }
    }
    return ImageOpenPlan(imageURLs: images, mediaURLs: media)
  }

  /// Image success must not be mistaken for an empty playlist by callers.
  func combinedCount(with mediaCount: Int?) -> Int? {
    imageCount == 0 ? mediaCount : imageCount + (mediaCount ?? 0)
  }
}

/// Keep image windows independent from mpv and alive after the opening action returns.
final class ImageViewerCoordinator {
  static let shared = ImageViewerCoordinator()
  private var controller: ImageViewerWindowController?
  private var isOpening = false
  private var isShuttingDown = false
  private(set) var hasOpenedImages = false

  var isBusy: Bool { isOpening || (controller?.isBusy ?? false) }
  var isActiveForUpdate: Bool { isBusy || (controller?.isActiveForUpdate ?? false) }

  static var blocksPlaybackMenu: Bool {
    blocksPlaybackMenu(keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow)
  }

  /// App-level menu selectors must not fall back to an unrelated video behind an image window.
  static func blocksPlaybackMenu(keyWindow: NSWindow?, mainWindow: NSWindow?) -> Bool {
    func owner(of window: NSWindow?) -> NSWindow? {
      var result = window
      while let parent = result?.sheetParent { result = parent }
      return result
    }
    let key = owner(of: keyWindow)
    // A real video window takes priority during an AppKit main-window transition.
    if key?.windowController is PlayerWindowController { return false }
    return key?.windowController is ImageViewerWindowController ||
      owner(of: mainWindow)?.windowController is ImageViewerWindowController
  }

  @discardableResult
  func openImages(in urls: [URL]) -> ImageOpenPlan {
    precondition(Thread.isMainThread, "Image windows must be opened on the main thread")
    let plan = ImageOpenPlan.make(urls, playbackExtensions: Set(Utility.playableFileExt))
    guard !UpdateWorkAdmission.shared.isBlocked, !isShuttingDown, !plan.imageURLs.isEmpty else { return plan }
    isOpening = true
    defer { isOpening = false }
    if let controller {
      controller.open(urls: plan.imageURLs)
    } else {
      controller = ImageViewerWindowController(urls: plan.imageURLs)
    }
    controller?.showWindow(nil)
    controller?.window?.makeKeyAndOrderFront(nil)
    hasOpenedImages = true
    // Show the replacement window before closing welcome windows to avoid an auto-quit gap.
    for player in PlayerCore.playerCores where player.initialWindow.loaded {
      player.initialWindow.close()
    }
    return plan
  }

  func cancelAndClose() {
    isShuttingDown = true
    controller?.cancelAndClose()
    controller = nil
  }
}
