import Cocoa

_ = NSApplication.shared
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
  guard value() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}

func label(_ title: String, identifier: String? = nil) -> NSTextField {
  let field = NSTextField(labelWithString: title)
  field.textColor = .labelColor
  if let identifier { field.identifier = NSUserInterfaceItemIdentifier(identifier) }
  return field
}

func collapsed(_ content: NSView) -> CollapseView {
  let trigger = NSButton()
  trigger.bezelStyle = .disclosure
  trigger.identifier = NSUserInterfaceItemIdentifier("Trigger0")
  trigger.state = .off
  content.identifier = NSUserInterfaceItemIdentifier("Content0")
  let result = CollapseView(views: [trigger, content])
  result.detachesHiddenViews = true
  return result
}

let controller = PreferenceWindowController(viewControllers: [])
let section = NSView()
let sectionTitle = label("Subtitles:", identifier: "SectionTitleSubtitles")
let kept = label("Font")
let retired = label("Retired setting")
retired.isHidden = true
section.addSubview(sectionTitle)
section.addSubview(kept)
section.addSubview(retired)
check(controller.getLabelDict(in: [section])["Subtitles"] == ["Font"],
      "Visible sections and rows are indexed without hidden rows")
check(controller.findLabel(titled: "Retired setting", in: section) == nil,
      "Hidden rows cannot be selected by search")

let retiredSection = NSView()
retiredSection.addSubview(label("ReplayGain:", identifier: "SectionTitleReplayGain"))
retiredSection.isHidden = true
check(controller.getLabelDict(in: [section, retiredSection])["ReplayGain"] == nil,
      "Hidden sections are not indexed")

let advanced = NSView()
let language = label("Preferred language")
advanced.addSubview(language)
let inner = collapsed(advanced)
let outerContent = NSView()
outerContent.addSubview(inner)
let outer = collapsed(outerContent)
section.addSubview(outer)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = section
section.layoutSubtreeIfNeeded()
check(inner.folded && outer.folded, "Real AppKit nested sections start collapsed")
check(advanced.isHidden && outerContent.isHidden, "Collapsed content is hidden by NSStackView")
check(controller.findLabels(in: section).contains("Preferred language"),
      "Collapsed supported settings remain searchable")
check(controller.findLabel(titled: "Preferred language", in: section) === language,
      "Search finds controls through the stack's logical children")
check(controller.revealSearchResult(language, in: section),
      "Search result can be revealed from the current page")
check(!inner.folded && !outer.folded, "Selecting a nested result expands every enclosing section")
check(!controller.revealSearchResult(NSView(), in: section), "Unrelated views are not reported as revealed")

let keyboardPage = NSView()
let marker = label("Settings:", identifier: "SectionTitleSettings")
marker.isHidden = true
keyboardPage.addSubview(marker)
keyboardPage.addSubview(label("Use system media control"))
check(controller.getLabelDict(in: [keyboardPage])["Settings"] == ["Use system media control"],
      "Single-page keyboard settings support the hidden section marker")

print("Preference search checks passed: \(checks)")
