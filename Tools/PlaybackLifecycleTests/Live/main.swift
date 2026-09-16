import Foundation

enum Logger {
  enum Level { case debug, error }
  static func ensure(_ condition: Bool, _ message: String) { precondition(condition, message) }
}
enum MPVProperty {
  static let vf = "vf"
  static let af = "af"
}
struct MPVFilter {
  let name: String
  let label: String?
  let params: [String: String]?
}
enum IINAError: Error { case unsupportedMPVNodeFormat(UInt32) }

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
}

guard let handle = mpv_create() else { fatalError("Unable to create the actual libmpv core") }
defer { mpv_terminate_destroy(handle) }
let controller = FilterControllerUnderTest(handle)
check(controller.getFilters("vf").isEmpty, "Actual uninitialized libmpv filter reads fail safely")
check(!controller.removeFilter("vf", 0), "Actual uninitialized libmpv removal fails safely")
for (key, value) in ["vo": "null", "ao": "null", "idle": "yes", "terminal": "no", "config": "no"] {
  check(mpv_set_option_string(handle, key, value) >= 0, "Configure headless libmpv: \(key)")
}
check(mpv_initialize(handle) >= 0, "Initialize actual libmpv")
check(mpv_command_string(handle, "vf set hflip,vflip,hflip") >= 0, "Add actual mpv video filters")
check(controller.getFilters("vf").map(\.name) == ["hflip", "vflip", "hflip"], "Read actual C filter node trees")
check(!controller.removeFilter("vf", -1), "Actual filter removal rejects a negative index")
check(!controller.removeFilter("vf", 3), "Actual filter removal rejects a stale index")
check(controller.removeFilter("vf", 1), "Remove an actual middle filter")
check(controller.getFilters("vf").map(\.name) == ["hflip", "hflip"], "Only the actual selected filter is removed")
check(controller.removeFilter("vf", 0) && controller.removeFilter("vf", 0), "Remove the actual first and only filters")
check(controller.getFilters("vf").isEmpty, "Actual filter list becomes empty")
check(!controller.removeFilter("vf", 0), "Actual empty filter list rejects removal")
controller.mpv = nil
check(controller.getFilters("vf").isEmpty && !controller.removeFilter("vf", 0), "Destroyed-handle paths avoid the C API")
print("Live libmpv filter checks passed: \(checks)")
