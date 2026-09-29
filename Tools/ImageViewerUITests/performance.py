#!/usr/bin/env python3
"""Compare production presentation paths with a local baseline using synthetic metadata."""

import argparse
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BASELINE = "ce576ab861c3b4cfeeb2cf98b7db0c8e06dee39b"
sys.dont_write_bytecode = True
sys.path.insert(0, str(PROJECT_ROOT))

from other.test_app_workspace import TestAppWorkspace

HARNESS = r'''
import Cocoa

func measure(_ name: String, _ operation: () -> Void) {
  var times: [Double] = []
  for _ in 0..<5 {
    let start = CACurrentMediaTime()
    operation()
    times.append((CACurrentMediaTime() - start) * 1000)
  }
  print(String(format: "PERF version=VERSION path=%@ median_ms=%.3f", name, times.sorted()[2]))
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.finishLaunching()
let root = FileManager.default.temporaryDirectory.appendingPathComponent("image-performance-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let items = (0..<20_000).map { index in
  PlaylistFileMetadata(url: root.appendingPathComponent("Image \((index * 7919) % 20_000).png"),
    fileSize: 1234, modificationDate: Date(timeIntervalSince1970: 123456),
    creationDate: Date(timeIntervalSince1970: 654321), tags: [PlaylistFileTag(name: "Fixture", colorIndex: index % 8)])
}
let defaults = UserDefaults(suiteName: "io.chengying.performance.\(UUID().uuidString)")!
let viewer = ImageViewerWindowController(urls: [], defaults: defaults)
viewer.files = items
viewer.selectedURL = items.last!.url
measure("frame-controls-120x-20000-files") {
  for _ in 0..<120 { FRAME_UPDATE }
}
precondition(viewer.files == items && viewer.selectedURL == items.last!.url)

let browser = MediaFolderBrowserView(extensions: ["png"])
browser.entries = items.map { MediaFolderBrowserView.Entry(metadata: $0, isDirectory: false) }
browser.applyPresentation()
let completeOrder = browser.mediaFiles
measure("folder-filter-5x-20000-files") {
  for filter in [PlaylistTagFilter.color(6), .all, .untagged, .color(2), .all] {
    browser.tagFilterControls.onFilterChange?(filter)
  }
}
precondition(browser.mediaFiles == completeOrder && browser.visibleEntries.map(\.metadata) == completeOrder)

let identityItems = Array(items.prefix(5000))
viewer.directoryURL = root
viewer.selectedURL = identityItems.last!.url
viewer.folderBrowser.mediaFiles = identityItems
viewer.folderDidLoad(root)
measure("image-folder-callback-5x-5000-files") {
  for _ in 0..<5 { viewer.folderDidLoad(root) }
}
precondition(viewer.files == identityItems && viewer.selectedURL == identityItems.last!.url)

CELL_SETUP
measure("image-cell-1000-configurations") {
  for index in 0..<1000 {
    autoreleasepool {
      CELL_CONFIGURE
      precondition(cell.textField?.stringValue == identityItems[index].name)
      precondition(cell.toolTip?.contains("Fixture") == true)
    }
  }
}
viewer.window?.orderOut(nil)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref", default=DEFAULT_BASELINE,
                        help="Locally available pre-optimization commit; never fetched from the network")
    arguments = parser.parse_args()
    source_paths = [
        "iina/Updates/UpdateWorkAdmission.swift",
        "iina/MediaInfo/MediaInfoModels.swift",
        "iina/ImageViewer/ImageSlideshowPolicy.swift",
        "iina/PlaylistFileMetadata.swift",
        "iina/ChengYingStyle.swift",
        "iina/PlaylistPresentation.swift",
        "iina/ImageViewer/ImageEditing.swift",
        "iina/ImageViewer/ImageCropGeometry.swift",
        "iina/ImageViewer/ImageEditingPanel.swift",
        "iina/ImageViewer/ImageCanvasView.swift",
        "Tools/ImageViewerUITests/AppStubs.swift",
        "Tools/ImageViewerUITests/Stubs.swift",
    ]
    modified_paths = ["iina/MediaFolderBrowserView.swift", "iina/ImageViewer/ImageViewerWindowController.swift"]
    try:
        base = subprocess.check_output(["git", "rev-parse", "--verify", f"{arguments.baseline_ref}^{{commit}}"],
                                       cwd=PROJECT_ROOT, text=True, stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        parser.error("The baseline commit is not available locally; provide an existing --baseline-ref.")
    print(f"PERF baseline_commit={base}", flush=True)
    print("PERF compiler=swiftc-O samples=5 statistic=median excludes=compilation,fixture-creation,image-decoding "
          "includes=synthetic-path-resolution,AppKit-presentation", flush=True)
    with TestAppWorkspace(prefix="image-performance-") as directory:
        workspace = Path(directory)
        for version in ("baseline", "current"):
            target = workspace / version
            target.mkdir()
            sources = [str(PROJECT_ROOT / source) for source in source_paths]
            for relative in modified_paths:
                text = (subprocess.check_output(["git", "show", f"{base}:{relative}"], cwd=PROJECT_ROOT, text=True)
                        if version == "baseline" else (PROJECT_ROOT / relative).read_text())
                # Expose the real methods only in disposable benchmark source copies.
                text = text.replace("private(set) ", "").replace("private ", "")
                source = target / Path(relative).name
                source.write_text(text)
                sources.append(str(source))
            harness = HARNESS.replace("VERSION", version)
            harness = harness.replace("FRAME_UPDATE", "viewer.updateControls()" if version == "baseline"
                                      else "viewer.updateFrameControls()")
            harness = harness.replace("CELL_SETUP", "" if version == "baseline" else "let cell = ImageFileListCell()")
            harness = harness.replace("CELL_CONFIGURE", "let cell = viewer.tableView(viewer.tableView, viewFor: nil, row: index) as! NSTableCellView"
                                      if version == "baseline" else "cell.configure(identityItems[index], showCreated: false)")
            main_source = target / "main.swift"
            main_source.write_text(harness)
            executable = target / "ImagePresentationPerformance"
            subprocess.run(["xcrun", "swiftc", "-O", "-o", str(executable), *sources, str(main_source)], check=True)
            subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
