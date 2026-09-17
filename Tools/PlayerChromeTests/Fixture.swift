import Cocoa

/// Rebuilds the real XIB fragment constraints without requiring Xcode or the playback engine.
final class ChromeFixture {
  private var views: [String: NSView] = [:]
  private var elements: [String: XMLElement] = [:]
  private var constraintsByID: [String: NSLayoutConstraint] = [:]
  let source: XMLDocument

  init(xib: URL) throws {
    source = try XMLDocument(contentsOf: xib)
    for root in try source.nodes(forXPath: "/document/objects/*") {
      guard let element = root as? XMLElement, let id = element.attribute(forName: "id")?.stringValue else { continue }
      elements[id] = element
    }
  }

  func view(_ id: String) -> NSView { views[id]! }

  func constraint(forOutlet property: String) throws -> NSLayoutConstraint {
    let nodes = try source.nodes(forXPath: "/document/objects/customObject[@id='-2']/connections/outlet[@property='\(property)']")
    guard nodes.count == 1, let outlet = nodes.first as? XMLElement,
          let id = outlet.attribute(forName: "destination")?.stringValue, let constraint = constraintsByID[id] else {
      fatalError("Missing XIB constraint outlet: \(property)")
    }
    return constraint
  }

  private func timelineView() throws -> NSView {
    let archiver = NSKeyedArchiver(requiringSecureCoding: false)
    archiver.setClassName("ChromeTimelineArchive", for: NSView.self)
    archiver.encode(NSView(frame: .zero), forKey: NSKeyedArchiveRootObjectKey)
    archiver.finishEncoding()
    let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
    unarchiver.requiresSecureCoding = false
    unarchiver.setClass(TimeLabelOverflowedView.self, forClassName: "ChromeTimelineArchive")
    defer { unarchiver.finishDecoding() }
    return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as! TimeLabelOverflowedView
  }

  func fragment(_ id: String) throws -> NSView {
    let root = elements[id]!
    let view = try makeView(root)
    try installConstraints(root)
    return view
  }

  private func makeView(_ element: XMLElement) throws -> NSView {
    let id = element.attribute(forName: "id")!.stringValue!
    let view: NSView
    switch element.name! {
    case "stackView":
      let stack = NSStackView()
      stack.orientation = .horizontal
      stack.alignment = .centerY
      stack.spacing = 0
      if element.attribute(forName: "distribution")?.stringValue == "fillEqually" { stack.distribution = .fillEqually }
      view = stack
    case "button":
      let names = ["2py-h1-0km": "speaker.wave.2.fill", "10x-bg-xlj": "backward.fill",
                   "gxw-pJ-Lcg": "play.fill", "EIi-qd-glM": "forward.fill"]
      let button: NSButton
      if let name = names[id] {
        button = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: id)!, target: nil, action: nil)
      } else {
        let title = element.elements(forName: "buttonCell").first?.attribute(forName: "title")?.stringValue ?? ""
        button = NSButton(title: title, target: nil, action: nil)
      }
      button.isBordered = false
      button.contentTintColor = .white
      button.imageScaling = .scaleProportionallyDown
      view = button
    case "slider":
      let slider = NSSlider(value: 28, minValue: 0, maxValue: 100, target: nil, action: nil)
      slider.isContinuous = true
      if id == "SAG-kc-FAt" { slider.controlSize = .mini }
      view = slider
    case "textField":
      let field = NSTextField(labelWithString: id == "NBD-MV-OuG" ? "02:47" : "−07:20")
      field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
      field.textColor = .white
      field.alignment = .center
      if id == "qOq-6a-7j7" { field.isHidden = true }
      view = field
    case "box":
      let box = NSBox()
      box.boxType = .separator
      view = box
    case "tabView":
      let tabs = NSTabView()
      tabs.tabViewType = .noTabsNoBorder
      for node in try element.nodes(forXPath: "tabViewItems/tabViewItem/view") {
        let item = NSTabViewItem()
        item.view = try makeView(node as! XMLElement)
        item.view?.translatesAutoresizingMaskIntoConstraints = true
        tabs.addTabViewItem(item)
      }
      tabs.selectTabViewItem(at: 0)
      view = tabs
    case "scrollView":
      let scroll = NSScrollView()
      scroll.borderType = .noBorder
      scroll.hasVerticalScroller = true
      let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
      table.headerView = nil
      table.rowHeight = 26
      table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Filename")))
      scroll.documentView = table
      view = scroll
    default:
      view = id == "BE1-yC-oJL" ? try timelineView() : NSView(frame: .zero)
    }
    view.identifier = NSUserInterfaceItemIdentifier(id)
    view.translatesAutoresizingMaskIntoConstraints = element.attribute(forName: "fixedFrame")?.stringValue == "YES"
    views[id] = view
    for child in try element.nodes(forXPath: "subviews/*") {
      let subview = try makeView(child as! XMLElement)
      if let stack = view as? NSStackView { stack.addView(subview, in: .center) } else { view.addSubview(subview) }
    }
    return view
  }

  private func installConstraints(_ element: XMLElement) throws {
    let id = element.attribute(forName: "id")!.stringValue!
    let attributes: [String: NSLayoutConstraint.Attribute] = [
      "width": .width, "height": .height, "leading": .leading, "trailing": .trailing,
      "left": .left, "right": .right, "top": .top, "bottom": .bottom, "centerX": .centerX, "centerY": .centerY,
    ]
    for node in try element.nodes(forXPath: "constraints/constraint") {
      let constraint = node as! XMLElement
      func text(_ key: String) -> String? { constraint.attribute(forName: key)?.stringValue }
      let first = views[text("firstItem") ?? id]!
      let second = text("secondItem").flatMap { views[$0] }
      let relation: NSLayoutConstraint.Relation = text("relation") == "greaterThanOrEqual" ? .greaterThanOrEqual :
        (text("relation") == "lessThanOrEqual" ? .lessThanOrEqual : .equal)
      let ratio = (text("multiplier") ?? "1").split(separator: ":").map { Double($0)! }
      let multiplier = ratio.count == 2 ? ratio[0] / ratio[1] : ratio[0]
      var constant = Double(text("constant") ?? "0")!
      // The edge layout deliberately uses the compact bottom-mode spacing.
      if ["aEy-x5-Ctd", "WtE-JF-0m3"].contains(text("id")!) { constant = 16 }
      if ["GNu-nJ-qPy", "oEb-w7-DDS"].contains(text("id")!) { constant = 3 }
      let native = NSLayoutConstraint(item: first, attribute: attributes[text("firstAttribute")!]!, relatedBy: relation,
                                      toItem: second, attribute: second == nil ? .notAnAttribute : attributes[text("secondAttribute")!]!,
                                      multiplier: multiplier, constant: constant)
      native.identifier = text("id")
      constraintsByID[text("id")!] = native
      native.isActive = true
    }
    for child in try element.nodes(forXPath: "subviews/*") {
      try installConstraints(child as! XMLElement)
    }
    for child in try element.nodes(forXPath: "tabViewItems/tabViewItem/view") {
      try installConstraints(child as! XMLElement)
    }
  }
}

/// A synthetic video surface; no user files or reference-image media are included.
final class ChromeSampleVideo: NSView {
  var alternateBackground = false

  override func draw(_ dirtyRect: NSRect) {
    NSGradient(starting: alternateBackground ? .white : NSColor(srgbRed: 0.07, green: 0.12, blue: 0.19, alpha: 1),
               ending: NSColor(srgbRed: 0.25, green: 0.44, blue: 0.55, alpha: 1))!.draw(in: bounds, angle: 45)
    NSColor.white.withAlphaComponent(0.08).setStroke()
    let grid = NSBezierPath()
    for fraction in [0.25, 0.5, 0.75] {
      grid.move(to: NSPoint(x: bounds.width * fraction, y: 0))
      grid.line(to: NSPoint(x: bounds.width * fraction, y: bounds.height))
      grid.move(to: NSPoint(x: 0, y: bounds.height * fraction))
      grid.line(to: NSPoint(x: bounds.width, y: bounds.height * fraction))
    }
    grid.stroke()
    let title = "Sample Video.mp4"
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .medium),
                                                   .foregroundColor: NSColor.white.withAlphaComponent(0.7)]
    let size = title.size(withAttributes: attributes)
    title.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height / 2), withAttributes: attributes)
  }
}
