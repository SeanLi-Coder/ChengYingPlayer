import Foundation
import Darwin

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let url = root.appendingPathComponent("synthetic.mp4")
try Data("Synthetic file only".utf8).write(to: url, options: .withoutOverwriting)

func inspect(_ step: String) throws {
  var fresh = URL(fileURLWithPath: url.path)
  fresh.removeAllCachedResourceValues()
  let values = try fresh.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
  var bytes = [UInt8](repeating: 0, count: 65536)
  let count = getxattr(url.path, "com.apple.metadata:_kMDItemUserTags", &bytes, bytes.count, 0, 0)
  let raw = count > 0 ? try PropertyListSerialization.propertyList(from: Data(bytes.prefix(count)), format: nil) : []
  print("\(step): names=\(values.tagNames ?? []), label=\(values.labelNumber ?? -1), raw=\(raw)")
}
func set(_ values: URLResourceValues) throws {
  var fresh = URL(fileURLWithPath: url.path)
  try fresh.setResourceValues(values)
}
var values = URLResourceValues()
values.tagNames = ["Keep custom", "Second"]
try set(values)
try inspect("names only")
for index in 1...7 {
  values = URLResourceValues()
  values.labelNumber = index
  try set(values)
  try inspect("label \(index)")
}
values = URLResourceValues()
values.labelNumber = 0
try set(values)
try inspect("remove label")
values = URLResourceValues()
values.tagNames = ["Keep custom", "Red\n6", "Blue\n4"]
try set(values)
try inspect("explicit suffixed tag names")
let tagged = try PropertyListSerialization.data(fromPropertyList: ["Keep custom\n0", "Review\n6", "Blue\n4"],
                                               format: .binary, options: 0)
let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
precondition(fd >= 0)
defer { close(fd) }
precondition(tagged.withUnsafeBytes {
  fsetxattr(fd, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, $0.count, 0, 0)
} == 0)
try inspect("descriptor tag write")
