import Foundation
import CoreMedia

@main
struct SwiftEOFTest {
  static func main() throws {
    let decoder = CYNMediaDecoder()
    let url = URL(fileURLWithPath:CommandLine.arguments[1])
    guard let info = try decoder.open(url), info.hasVideo else {
      fatalError("Expected video information")
    }
    var count = 0
    while let sample = try decoder.readSample() {
      precondition(CMSampleBufferIsValid(sample.sampleBuffer))
      count += 1
      precondition(count < 5000)
    }
    precondition(count > 120)
    let repeatedEOF: CYNMediaSample? = try decoder.readSample()
    precondition(repeatedEOF == nil)
    try decoder.seek(to: 1)
    let afterSeek = try decoder.readSample()
    precondition(afterSeek != nil)
    decoder.cancel()
    do {
      _ = try decoder.readSample()
      fatalError("Cancellation must throw")
    } catch {
      precondition((error as NSError).code == 4)
    }
    decoder.close()
    print("PASS Swift optional EOF, seek, cancellation; samples=\(count)")
  }
}
