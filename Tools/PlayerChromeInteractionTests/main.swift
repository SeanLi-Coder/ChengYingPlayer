import Cocoa
import ObjectiveC

setbuf(stdout, nil)
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError("FAIL: \(message)") }
  checks += 1
  print("PASS: \(message)")
}

func window() -> NSWindow {
  let result = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
  result.isReleasedWhenClosed = false
  return result
}

func playSlider() throws -> PlaySlider {
  // Decode a locally generated AppKit archive through the production coder initializer.
  let source = NSSlider(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
  source.cell = PlaySliderCell()
  source.maxValue = 100
  let data = try NSKeyedArchiver.archivedData(withRootObject: source, requiringSecureCoding: false)
  let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
  decoder.requiresSecureCoding = false
  decoder.setClass(PlaySlider.self, forClassName: "NSSlider")
  defer { decoder.finishDecoding() }
  guard let slider = decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? PlaySlider else {
    fatalError("FAIL: The production PlaySlider coder initializer was not used")
  }
  return slider
}

func event(_ type: NSEvent.EventType = .leftMouseDown, in window: NSWindow, x: CGFloat = 80, y: CGFloat = 24) -> NSEvent {
  NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
}

// Replace only NSSlider's blocking platform tracking loop. All production overrides run as compiled.
// This lets a deterministic callback move or detach a slider before super.mouseDown returns.
func tracking(_ callback: @escaping (NSSlider) -> Void, perform action: () -> Void) {
  let method = class_getInstanceMethod(NSSlider.self, #selector(NSResponder.mouseDown(with:)))!
  let block: @convention(block) (NSSlider, NSEvent) -> Void = { slider, _ in callback(slider) }
  let replacement = imp_implementationWithBlock(block)
  let original = method_setImplementation(method, replacement)
  defer {
    method_setImplementation(method, original)
    imp_removeBlock(replacement)
  }
  action()
}

let first = MainWindowController(window: window())
let second = MainWindowController(window: window())
let mini = MiniPlayerWindowController(window: window())
defer { first.close(); second.close(); mini.close() }
let progress = try playSlider()
let volume = VolumeSlider(frame: NSRect(x: 20, y: 60, width: 200, height: 24))

check(class_getInstanceMethod(PlaySlider.self, #selector(NSResponder.mouseDown(with:))).map(method_getImplementation) !=
      class_getInstanceMethod(NSSlider.self, #selector(NSResponder.mouseDown(with:))).map(method_getImplementation),
      "The production PlaySlider retains its distinct Tahoe mouseDown override")

for (name, slider) in [("progress", progress as NSSlider), ("volume", volume as NSSlider)] {
  first.window!.contentView!.addSubview(slider)
  var entered = false
  let initialBegins = first.begins
  let initialEnds = first.ends
  tracking({ current in
    entered = true
    check(current === slider && first.depth == 1, "\(name) locks chrome before native tracking begins")
    check(first.ends == initialEnds, "\(name) does not end its interaction during native tracking")
  }, perform: { slider.mouseDown(with: event(in: first.window!)) })
  check(entered && first.begins == initialBegins + 1 && first.ends == initialEnds + 1 && first.depth == 0,
        "\(name) balances begin and end when native tracking returns")

  let secondEnds = second.ends
  tracking({ current in
    check(first.depth == 1, "\(name) remains protected before crossing windows")
    second.window!.contentView!.addSubview(current)
    check(first.depth == 1 && second.depth == 0, "\(name) keeps the originating owner while moving to another window")
  }, perform: { slider.mouseDown(with: event(in: first.window!)) })
  check(first.depth == 0 && second.ends == secondEnds, "\(name) returns the interaction to its original owner only")

  first.window!.contentView!.addSubview(slider)
  tracking({ current in
    current.removeFromSuperview()
    check(first.depth == 1, "\(name) stays protected until detached native tracking unwinds")
  }, perform: { slider.mouseDown(with: event(in: first.window!)) })
  check(first.depth == 0, "\(name) releases a detached interaction exactly once")

  mini.window!.contentView!.addSubview(slider)
  let counts = (first.begins, second.begins)
  tracking({ _ in
    check(first.depth == 0 && second.depth == 0, "\(name) does not treat the mini player as a main window")
  }, perform: { slider.mouseDown(with: event(in: mini.window!)) })
  check(counts == (first.begins, second.begins), "\(name) performs no main-window interactions for a mini player")
}

first.window!.contentView!.addSubview(progress)
first.window!.contentView!.addSubview(volume)
tracking({ current in
  if current === progress {
    check(first.depth == 1, "The outer progress interaction is active before nested tracking")
    volume.mouseDown(with: event(in: first.window!))
    check(first.depth == 1, "Finishing a nested volume interaction preserves the outer progress lock")
  } else {
    check(current === volume && first.depth == 2, "Nested native tracking holds two balanced interactions")
  }
}, perform: { progress.mouseDown(with: event(in: first.window!)) })
check(first.depth == 0, "Nested native tracking releases both interactions after unwinding")

let knob = progress.abLoopA
knob.isHidden = false
knob.setFrameOrigin(NSPoint(x: 60, y: 0))
let knobPoint = progress.convert(NSPoint(x: knob.frame.midX, y: knob.frame.midY), to: nil)
knob.mouseDown(with: event(in: first.window!, x: knobPoint.x, y: knobPoint.y))
check(first.depth == 1, "The production A-B mouseDown hit path starts interaction protection")
let begins = first.begins
knob.beginDragging(with: event(in: first.window!))
check(first.depth == 1 && first.begins == begins, "Repeated A-B drag starts hold one interaction")
second.window!.close()
check(first.depth == 1, "Closing another window cannot cancel the source A-B interaction")
knob.mouseDragged(with: event(.leftMouseDragged, in: second.window!, x: -100))
check(first.depth == 1 && second.depth == 0, "Dragging A-B outside the source window keeps its source interaction")
knob.mouseUp(with: event(.leftMouseUp, in: second.window!))
check(first.depth == 0, "A-B mouse-up outside the source window releases its owner")
let ended = first.ends
knob.mouseUp(with: event(.leftMouseUp, in: second.window!))
check(first.ends == ended, "Repeated A-B mouse-up cannot release an unrelated interaction")

knob.beginDragging(with: event(in: first.window!))
knob.isHidden = true
check(first.depth == 0, "Hiding the active A-B knob cancels its interaction")
knob.isHidden = false
knob.beginDragging(with: event(in: first.window!))
progress.isHidden = true
check(first.depth == 0, "Hiding the A-B knob's parent cancels its interaction")
progress.isHidden = false

knob.beginDragging(with: event(in: first.window!))
second.window!.contentView!.addSubview(progress)
check(first.depth == 0 && second.depth == 0, "Moving an A-B knob to another window cleans up only the original owner")
knob.mouseUp(with: event(.leftMouseUp, in: second.window!))
check(second.depth == 0, "A-B mouse-up after reparenting cannot decrement the destination owner")
knob.beginDragging(with: event(in: second.window!))
progress.removeFromSuperview()
check(second.depth == 0, "Detaching the A-B hierarchy cancels its interaction")

first.window!.contentView!.addSubview(progress)
knob.beginDragging(with: event(in: first.window!))
check(first.depth == 1, "The closing-window A-B fixture begins protected")
first.window!.close()
check(first.depth == 0, "The actual window-close notification cancels an outstanding A-B interaction")
let closeEnds = first.ends
knob.mouseUp(with: event(.leftMouseUp, in: first.window!))
check(first.ends == closeEnds, "A late mouse-up after closing does not release again")

mini.window!.contentView!.addSubview(progress)
let mainCounts = (first.begins, second.begins)
knob.beginDragging(with: event(in: mini.window!))
knob.mouseUp(with: event(.leftMouseUp, in: mini.window!))
check(mainCounts == (first.begins, second.begins), "A-B knobs in mini players do not cast or lock a main window")

print("Player chrome interaction checks passed: \(checks)")
