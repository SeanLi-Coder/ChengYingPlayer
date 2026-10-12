// Executes only the actual driver's extracted pixel comparator. This is not
// evidence of an application window, renderer presentation or playback.
import CoreVideo
import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
  checks += 1
  guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
}
func buffer(width: Int = 160, height: Int = 96,
            format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) -> CVPixelBuffer {
  var result: CVPixelBuffer?
  check(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &result) == kCVReturnSuccess,
        "Allocate synthetic pixel buffer")
  return result!
}
let image = buffer()
var reference: [Int] = []
check(CVPixelBufferLockBaseAddress(image, []) == kCVReturnSuccess, "Lock synthetic pixel storage")
var components: [UnsafeMutablePointer<UInt8>] = []
for y in [8, 48, 86] {
  for x in [8, 80, 150] {
    let luma = CVPixelBufferGetBaseAddressOfPlane(image, 0)!
      .advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(image, 0)).assumingMemoryBound(to: UInt8.self)
    let chroma = CVPixelBufferGetBaseAddressOfPlane(image, 1)!
      .advanced(by: y / 2 * CVPixelBufferGetBytesPerRowOfPlane(image, 1)).assumingMemoryBound(to: UInt8.self)
    components += [luma.advanced(by: x), chroma.advanced(by: x / 2 * 2), chroma.advanced(by: x / 2 * 2 + 1)]
  }
}
for (index, address) in components.enumerated() {
  address.pointee = UInt8(30 + index * 6)
  reference.append(Int(address.pointee))
}
CVPixelBufferUnlockBaseAddress(image, [])
check(PixelComparator.matchesReference(image, reference), "Every distributed point matches its own reference")
for index in reference.indices {
  var changed = reference
  changed[index] += 1
  check(PixelComparator.matchesReference(image, changed), "One code value tolerance accepts component \(index)")
  changed[index] += 1
  check(!PixelComparator.matchesReference(image, changed), "Corrupted luma or chroma rejects component \(index)")
}
check(!PixelComparator.matchesReference(buffer(width: 158), reference), "Wrong displayed dimensions cannot pass")
check(!PixelComparator.matchesReference(buffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), reference),
      "Full-range output cannot pass as limited-range output")
check(!PixelComparator.matchesReference(buffer(format: kCVPixelFormatType_32BGRA), reference),
      "Unexpected pixel format cannot pass")
check(!PixelComparator.matchesReference(image, Array(reference.dropLast())), "Incomplete reference cannot pass")
var invalid = reference
invalid[0] = -1
check(!PixelComparator.matchesReference(image, invalid), "Out-of-range reference cannot pass")
check(PixelComparator.matchesVolumePercent(Double(Float(0.7)) * 100, 70),
      "Actual Float renderer volume round-trips through percent within representational tolerance")
check(PixelComparator.matchesVolumePercent(70, 70), "Exact requested volume is accepted")
for value: Double in [69, 0, .nan, .infinity, -.infinity] {
  check(!PixelComparator.matchesVolumePercent(value, 70), "Wrong or invalid volume cannot pass")
}
check(!PixelComparator.matchesVolumePercent(70, .nan), "Invalid expected volume cannot pass")
print("PASS: \(checks) actual driver pixel and volume comparator checks")
