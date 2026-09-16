import Cocoa

final class ImporterCheck: NSObject, FFmpegControllerDelegate {
  func didUpdate(_ thumbnails: [FFThumbnail]?, forFile filename: String, withProgress progress: Int, generation: UInt) {}
  func didGenerate(_ thumbnails: [FFThumbnail], forFile filename: String, succeeded: Bool, generation: UInt) {}

  func request(_ controller: FFmpegController) {
    controller.generateThumbnail(forFile: "/fixture.mp4", thumbWidth: 240, generation: 1)
    controller.cancelThumbnailGeneration()
  }
}
