import Cocoa
import QuartzCore

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  precondition(condition(), message)
  checks += 1
  print("PASS: \(message)")
}

let controller = ControlledController()
let battery = PowerSource()
battery.type = "InternalBattery"
battery.currentCapacity = 80
TestPowerSource.values = [battery]
controller.updateAdditionalInfo()
check(TestClock.reads == 1 && TestPowerSource.reads == 1, "The first visible update reads clock and power")
check(controller.additionalInfoLabel.stringValue == "12:00", "Initial clock text is preserved")
check(controller.additionalInfoBattery.stringValue == "80%", "Initial battery text is preserved")
check(controller.additionalInfoStackView.priority == .mustHold, "Battery visibility is preserved")
TestClock.text = "12:01"
battery.currentCapacity = 79
for index in 1..<25 {
  TestClock.now = 100 + Double(index) / 25
  controller.updateAdditionalInfo()
}
check(TestClock.reads == 1 && TestPowerSource.reads == 1, "Twenty-five playback ticks share one clock and power snapshot")
controller.window?.title = "Changed fixture"
controller.updateAdditionalInfo()
check(controller.additionalInfoTitle.stringValue == "Changed fixture", "Title changes remain immediate inside the time gate")
controller.window?.representedURL = URL(fileURLWithPath: "/synthetic/next-video.mp4")
controller.updateAdditionalInfo()
check(controller.additionalInfoTitle.stringValue == "next-video.mp4", "Changing files updates the displayed title immediately")
TestClock.now = 101
controller.updateAdditionalInfo()
check(TestClock.reads == 2 && TestPowerSource.reads == 2, "The exact one-second boundary permits a new snapshot")
check(controller.additionalInfoLabel.stringValue == "12:01" && controller.additionalInfoBattery.stringValue == "79%",
      "Clock and battery changes are visible at the next snapshot")
TestClock.now = 101.1
TestPowerSource.values = []
controller.updateAdditionalInfo(force: true)
check(TestClock.reads == 3 && TestPowerSource.reads == 3, "Fullscreen entry forces an immediate refresh inside the gate")
check(controller.additionalInfoStackView.priority == .notVisible, "A missing battery hides its status")
TestClock.now = 101.9
controller.updateAdditionalInfo()
check(TestClock.reads == 3, "A forced refresh resets the refresh deadline")
TestClock.now = 500
TestClock.text = "12:07"
check(TestClock.reads == 3 && TestPowerSource.reads == 3, "Hidden or paused status schedules no independent refresh")
controller.updateAdditionalInfo()
check(TestClock.reads == 4 && controller.additionalInfoLabel.stringValue == "12:07",
      "Showing status after an idle period refreshes immediately")

func syntheticImage(_ color: NSColor, size: NSSize = NSSize(width: 320, height: 180)) -> NSImage {
  let image = NSImage(size: size)
  image.lockFocus()
  color.setFill()
  NSRect(origin: .zero, size: size).fill()
  NSColor.white.setFill()
  NSRect(x: 0, y: 0, width: size.width / 3, height: size.height / 2).fill()
  image.unlockFocus()
  return image
}

func pixelData(_ image: NSImage) -> Data {
  let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
  return representation.representation(using: .png, properties: [:])!
}

_ = NSApplication.shared
let firstImage = syntheticImage(.red)
let otherImage = syntheticImage(.blue)
for angle in [0, 90, 180, 270, -90, 450, 45] {
  let expected = firstImage.rotate(angle)
  let actual = controller.thumbnailPreviewImage(for: firstImage, rotation: angle)
  check(actual.size == expected.size && pixelData(actual) == pixelData(expected),
        "Cached preview preserves pixels and dimensions at angle \(angle)")
}
let firstPreview = controller.thumbnailPreviewImage(for: firstImage, rotation: 90)
check(firstPreview !== firstImage, "A right-angle rotation creates the original transformed image")
for _ in 0..<1000 {
  precondition(controller.thumbnailPreviewImage(for: firstImage, rotation: 450) === firstPreview)
}
check(controller.cachedThumbnailPreviewImage === firstPreview, "Repeated hover events reuse one normalized-angle preview")
let rotatedAgain = controller.thumbnailPreviewImage(for: firstImage, rotation: 180)
check(rotatedAgain !== firstPreview, "A rotation change invalidates the cached preview")
let nextFilePreview = controller.thumbnailPreviewImage(for: otherImage, rotation: 180)
check(nextFilePreview !== rotatedAgain && pixelData(nextFilePreview) == pixelData(otherImage.rotate(180)),
      "A new source image from another file cannot reuse the previous preview")
weak var releasedSource: NSImage?
weak var releasedPreview: NSImage?
autoreleasepool {
  let transient = syntheticImage(.green)
  releasedSource = transient
  releasedPreview = controller.thumbnailPreviewImage(for: transient, rotation: 90)
}
check(releasedSource == nil, "The cache does not retain the source image")
check(releasedPreview != nil, "The cache owns only its current transformed output")
_ = controller.thumbnailPreviewImage(for: firstImage, rotation: 270)
check(releasedPreview == nil, "Replacing the current preview releases the preceding output")
check(controller.thumbnailPreviewImage(for: firstImage, rotation: 0) === firstImage,
      "Unrotated previews return the original image")
check(controller.cachedThumbnailPreviewImage == nil && controller.cachedThumbnailPreviewSource == nil,
      "An unrotated preview retains no redundant cache entry")
_ = controller.thumbnailPreviewImage(for: otherImage, rotation: 90)
controller.resetThumbnailPreviewCache()
check(controller.cachedThumbnailPreviewImage == nil && controller.cachedThumbnailPreviewSource == nil,
      "Unavailable thumbnails release the current cache entry")

func measure(_ name: String, iterations: Int, _ action: () -> Void) -> Double {
  for _ in 0..<10 { autoreleasepool { action() } }
  let start = CACurrentMediaTime()
  for _ in 0..<iterations { autoreleasepool { action() } }
  let elapsed = CACurrentMediaTime() - start
  print(String(format: "BENCH: %@ iterations=%d total_ms=%.3f us_per_call=%.3f", name, iterations,
               elapsed * 1000, elapsed * 1_000_000 / Double(iterations)))
  return elapsed
}

let iterations = 1000
var imageSink: NSImage?
let originalRotation = measure("uncached-rotation", iterations: iterations) {
  imageSink = firstImage.rotate(90)
}
let cachedRotation = measure("cached-rotation", iterations: iterations) {
  imageSink = controller.thumbnailPreviewImage(for: firstImage, rotation: 90)
}
check(imageSink != nil, "The rotation benchmark consumes its image output")
let native = NativeController()
let originalStatus = measure("unthrottled-native-status", iterations: iterations) {
  native.updateAdditionalInfo(force: true)
}
let cachedStatus = measure("coalesced-native-status", iterations: iterations) {
  native.updateAdditionalInfo()
}
print(String(format: "BENCH: rotation_speedup=%.2fx status_speedup=%.2fx", originalRotation / cachedRotation,
             originalStatus / cachedStatus))
print("Playback UI performance checks passed: \(checks)")
