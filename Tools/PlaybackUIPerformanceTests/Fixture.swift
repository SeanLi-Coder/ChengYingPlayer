import Cocoa

final class LabelFixture {
  var stringValue = ""
}

final class StackFixture {
  var priority = NSStackView.VisibilityPriority.notVisible
  func setVisibilityPriority(_ value: NSStackView.VisibilityPriority, for view: NSObject) {
    priority = value
  }
}

final class WindowFixture {
  var representedURL: URL?
  var title = "Synthetic fixture"
}

class ControllerFixture {
  var window: WindowFixture? = WindowFixture()
  let additionalInfoLabel = LabelFixture()
  let additionalInfoTitle = LabelFixture()
  let additionalInfoBattery = LabelFixture()
  let additionalInfoBatteryView = NSObject()
  let additionalInfoStackView = StackFixture()
}

enum TestClock {
  static var now = 100.0
  static var text = "12:00"
  static var reads = 0
  static func localizedString(from date: Date, dateStyle: DateFormatter.Style,
                              timeStyle: DateFormatter.Style) -> String {
    reads += 1
    return text
  }
}

enum TestPowerSource {
  static var values: [PowerSource] = []
  static var reads = 0
  static func getList() -> [PowerSource] {
    reads += 1
    return values
  }
}
