import Cocoa
import Darwin

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
var checks = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  checks += 1
  if !condition() { failures += 1; print("FAIL: " + message) }
}
func wait(_ message: String, until predicate: () -> Bool) {
  let deadline = Date().addingTimeInterval(5)
  while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
  check(predicate(), message)
}
func snapshot(_ url: URL) -> PlaybackFileTags.Snapshot {
  var result: Result<PlaybackFileTags.Snapshot, PlaybackFileTags.TagError>?
  PlaybackFileTags.read(url: url) { result = $0 }
  wait("The production reader returns a main-thread snapshot") { result != nil }
  guard case .success(let value)? = result else {
    print("FAIL: Fixture snapshot did not succeed: \(String(describing: result))")
    exit(1)
  }
  return value
}
func setTags(_ values: [String], at url: URL) throws {
  let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
  let status = data.withUnsafeBytes { setxattr(url.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, data.count, 0, 0) }
  guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
let first = root.appendingPathComponent("first.mp4")
let second = root.appendingPathComponent("second.mp4")
try Data("synthetic first fixture".utf8).write(to: first)
try Data("synthetic second fixture".utf8).write(to: second)
try setTags(["Keep custom\n6", "Remove custom\n6", "No color\n0", "Multi\nline\n4"], at: first)
var owner: PlaybackFileTagController.Owner? = .init(url: first, generation: 1)
var messages: [String] = []
var begins = 0
var ends = 0
var changes: [URL] = []
let observer = NotificationCenter.default.addObserver(forName: .playbackFileTagsChanged, object: nil, queue: .main) {
  if let url = $0.userInfo?["url"] as? URL { changes.append(url) }
}
let controller = PlaybackFileTagController(currentOwner: { owner }, beginInteraction: {
  begins += 1
  return { ends += 1 }
}, present: { messages.append($0) })
func invoke(_ item: NSMenuItem) {
  check(item.target === controller && item.action != nil, "The menu item targets the production controller")
  _ = app.sendAction(item.action!, to: item.target, from: item)
}
var current = snapshot(first)
var menu = controller.makeMenu(snapshot: current, owner: owner!)
check(menu.items.prefix(7).count == 7, "All seven Finder colors have menu actions")
check(menu.items[0].state == .on && !menu.items[0].isEnabled, "An existing color is checked and cannot be added again")
check(menu.items[1].isEnabled && menu.items[1].state == .off, "A missing color can be added")
check(menu.items[2].image != nil, "Colors also have native image representations")
check(menu.items.allSatisfy { !$0.title.contains("\n") }, "Control characters are removed only from presentation")
check(menu.items.filter { $0.action != nil }.count == 11, "Each existing tag gets its own exact removal action")
invoke(menu.items[0])
check(PlaybackFileTags.pendingWriteCount == 0 && changes.isEmpty, "A disabled add action does not write or notify")

owner = .init(url: second, generation: 2)
invoke(menu.items[1])
check(PlaybackFileTags.pendingWriteCount == 0 && changes.isEmpty, "A stale menu cannot tag a replacement video")
check(!messages.isEmpty, "Stale media ownership has an explicit explanation")
check(snapshot(second).tags.isEmpty, "The replacement video stays untouched")

owner = .init(url: first, generation: 3)
current = snapshot(first)
menu = controller.makeMenu(snapshot: current, owner: owner!)
let removal = menu.items.first { $0.title.contains("Remove custom") }!
invoke(removal)
check(!UpdateWorkAdmission.shared.activeReasons.isEmpty && !UpdateWorkAdmission.shared.isOpeningMediaBlocked,
      "A tag write blocks updates without blocking playback admission")
wait("An exact removal completes") { PlaybackFileTags.pendingWriteCount == 0 && changes.count == 1 }
current = snapshot(first)
check(current.tags.contains { $0.name == "Keep custom" && $0.colorIndex == 6 }, "Another tag of the same color is preserved")
check(!current.tags.contains { $0.name == "Remove custom" }, "Only the selected custom tag was removed")
check(current.tags.contains { $0.name == "Multi\nline" }, "Newlines in stored custom names are preserved")
check(UpdateWorkAdmission.shared.activeReasons.isEmpty, "Completion releases the update activity lease")

menu = controller.makeMenu(snapshot: current, owner: owner!)
let messageCount = messages.count
invoke(menu.items[1])
owner = .init(url: second, generation: 4)
wait("An accepted write completes after playback switches") { PlaybackFileTags.pendingWriteCount == 0 && changes.count == 2 }
check(changes.last == first, "The metadata notification targets the accepted original file")
check(messages.count == messageCount, "A late completion does not show a success message over another video")
check(snapshot(first).colors.contains(7) && snapshot(second).tags.isEmpty, "An accepted operation never retargets the new file")

owner = .init(url: first, generation: 5)
current = snapshot(first)
menu = controller.makeMenu(snapshot: current, owner: owner!)
try setTags(["Externally changed\n3"], at: first)
invoke(menu.items[2])
wait("An observed external tag change returns without writing") { PlaybackFileTags.pendingWriteCount == 0 }
check(snapshot(first).tags.map(\.name) == ["Externally changed"], "External Finder edits are preserved")
check(changes.count == 2 && UpdateWorkAdmission.shared.activeReasons.isEmpty, "Failure neither publishes success nor leaks admission")

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 80),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let anchor = NSButton(title: "Tags", target: nil, action: nil)
anchor.frame = NSRect(x: 5, y: 5, width: 60, height: 30)
window.contentView!.addSubview(anchor)
window.orderFront(nil)
controller.showMenu(from: anchor)
owner = .init(url: second, generation: 6)
wait("Switching media during metadata read cancels the menu and balances chrome interaction") { begins == 1 && ends == 1 }
controller.showMenu(from: anchor)
window.close()
wait("Closing the window during metadata read balances chrome interaction") { begins == 2 && ends == 2 }
NotificationCenter.default.removeObserver(observer)
let finalBytes = try Data(contentsOf: first)
check(finalBytes == Data("synthetic first fixture".utf8), "Tag edits preserve original media bytes")
print("Finder tag UI checks: \(checks), failures: \(failures)")
exit(failures == 0 ? 0 : 1)
