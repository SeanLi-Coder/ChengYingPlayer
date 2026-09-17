import Foundation

enum MediaInfoLoader {
  static func read(url: URL, kind: MediaInfoKind, token: MediaInfoCancellation) throws -> MediaInfoSnapshot {
    try token.check()
    let before = try MediaInfoFileIdentity(url: url)
    let file = try MediaInfoFileDetails.section(url: url)
    let metadata: MediaInfoContent
    switch kind {
    case .image:
      metadata = try ImageMediaInfoReader.read(url: url, token: token)
    case .video:
      guard let executable = Bundle.main.executableURL else { throw MediaInfoError.invalidSource }
      metadata = try VideoMediaInfoReader.read(url: url,
        ffprobeURL: executable.deletingLastPathComponent().appendingPathComponent("ffprobe"), token: token)
    }
    try token.check()
    guard try MediaInfoFileIdentity(url: url) == before else { throw MediaInfoError.changedSource }
    return MediaInfoSnapshot(url: url, kind: kind,
      content: MediaInfoContent(sections: [file] + metadata.sections, notes: metadata.notes))
  }
}
