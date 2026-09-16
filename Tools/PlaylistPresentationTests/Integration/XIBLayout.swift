import Cocoa

/// Reconstruct only the actual cell's subviews, outlets, and constraints from the
/// checked-in XIB. This runs on command-line-tools hosts without ibtool. It does
/// not claim to test NSNib decoding, Cocoa bindings, assets, or Interface Builder.
func makeProductionCell(xib: URL) throws -> PlaylistTrackCellView {
  let document = try XMLDocument(contentsOf: xib)
  guard let element = try document.nodes(forXPath: "//*[@customClass='PlaylistTrackCellView']").first as? XMLElement else {
    fatalError("The production playlist cell was not found in its XIB")
  }
  let cell = PlaylistTrackCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
  var views: [String: NSView] = [element.attribute(forName: "id")!.stringValue!: cell]
  var constraints: [String: NSLayoutConstraint] = [:]
  let children = try element.nodes(forXPath: "./subviews/*").compactMap { $0 as? XMLElement }
  for child in children {
    let view: NSView
    switch child.name {
    case "textField":
      let field = NSTextField(labelWithString: "")
      if let fieldCell = try child.nodes(forXPath: "./textFieldCell").first as? XMLElement {
        field.stringValue = fieldCell.attribute(forName: "title")?.stringValue ?? ""
        field.lineBreakMode = .byTruncatingMiddle
        if let font = try fieldCell.nodes(forXPath: "./font").first as? XMLElement {
          let size = Double(font.attribute(forName: "size")?.stringValue ?? "") ??
            (font.attribute(forName: "metaFont")?.stringValue == "smallSystemBold" ? 11 : 13)
          field.font = .systemFont(ofSize: size)
        }
      }
      field.textColor = .labelColor
      view = field
    case "button":
      let button = child.attribute(forName: "customClass")?.stringValue == "PlaylistPrefixButton" ?
        PlaylistPrefixButton() : NSButton()
      button.bezelStyle = .regularSquare
      button.isBordered = false
      if let buttonCell = try child.nodes(forXPath: "./buttonCell").first as? XMLElement {
        button.title = buttonCell.attribute(forName: "title")?.stringValue ?? ""
      }
      view = button
    case "customView":
      guard child.attribute(forName: "customClass")?.stringValue == "PlaylistPlaybackProgressView" else {
        fatalError("Unexpected production cell custom view")
      }
      view = PlaylistPlaybackProgressView()
    default: fatalError("Unsupported production cell XIB node: \(child.name ?? "nil")")
    }
    view.translatesAutoresizingMaskIntoConstraints = child.attribute(forName: "translatesAutoresizingMaskIntoConstraints")?.stringValue != "NO"
    view.isHidden = child.attribute(forName: "hidden")?.stringValue == "YES"
    for (attribute, orientation, hugging) in [
      ("horizontalHuggingPriority", NSLayoutConstraint.Orientation.horizontal, true),
      ("verticalHuggingPriority", .vertical, true),
      ("horizontalCompressionResistancePriority", .horizontal, false),
      ("verticalCompressionResistancePriority", .vertical, false),
    ] {
      if let value = child.attribute(forName: attribute)?.stringValue.flatMap(Float.init) {
        if hugging { view.setContentHuggingPriority(NSLayoutConstraint.Priority(value), for: orientation) }
        else { view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(value), for: orientation) }
      }
    }
    cell.addSubview(view)
    views[child.attribute(forName: "id")!.stringValue!] = view
  }
  let attributes: [String: NSLayoutConstraint.Attribute] = [
    "top": .top, "bottom": .bottom, "leading": .leading, "trailing": .trailing,
    "width": .width, "height": .height, "centerX": .centerX, "centerY": .centerY,
  ]
  for owner in [element] + children {
    let ownerView = views[owner.attribute(forName: "id")!.stringValue!]!
    for node in try owner.nodes(forXPath: "./constraints/constraint").compactMap({ $0 as? XMLElement }) {
      let first = node.attribute(forName: "firstItem")?.stringValue.flatMap { views[$0] } ?? ownerView
      let second = node.attribute(forName: "secondItem")?.stringValue.flatMap { views[$0] }
      let firstAttribute = attributes[node.attribute(forName: "firstAttribute")!.stringValue!]!
      let secondAttribute = node.attribute(forName: "secondAttribute")?.stringValue.flatMap { attributes[$0] } ?? .notAnAttribute
      let relation: NSLayoutConstraint.Relation = node.attribute(forName: "relation")?.stringValue == "greaterThanOrEqual" ? .greaterThanOrEqual : .equal
      let constraint = NSLayoutConstraint(item: first, attribute: firstAttribute, relatedBy: relation,
                                          toItem: second, attribute: secondAttribute, multiplier: 1,
                                          constant: Double(node.attribute(forName: "constant")?.stringValue ?? "0")!)
      let identifier = node.attribute(forName: "id")!.stringValue!
      constraint.identifier = identifier
      constraints[identifier] = constraint
      ownerView.addConstraint(constraint)
    }
  }
  for node in try element.nodes(forXPath: "./connections/outlet").compactMap({ $0 as? XMLElement }) {
    let destination = node.attribute(forName: "destination")!.stringValue!
    let target: Any = views[destination].map { $0 as Any } ?? constraints[destination].map { $0 as Any }!
    cell.setValue(target, forKey: node.attribute(forName: "property")!.stringValue!)
  }
  cell.awakeFromNib()
  return cell
}
