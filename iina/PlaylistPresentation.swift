import Cocoa

func playlistBrowserString(_ key: String) -> String {
  NSLocalizedString(key, tableName: "PlaylistBrowser", comment: "Local playlist browser")
}

extension PlaylistFileSortKey {
  var title: String { playlistBrowserString("sort.\(rawValue)") }
}

/// Compact controls sized for the player's 240-point minimum sidebar width.
final class PlaylistSortControls: NSView {
  let keyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  let directionButton = NSButton()
  let refreshButton = NSButton()
  var onSortChange: ((PlaylistFileSortKey, Bool) -> Void)?
  var onRefresh: (() -> Void)?
  private(set) var sortKey: PlaylistFileSortKey = .name
  private(set) var ascending = true

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    let label = NSTextField(labelWithString: playlistBrowserString("sort.label"))
    label.font = .systemFont(ofSize: 11, weight: .medium)
    label.textColor = .secondaryLabelColor
    keyPopup.font = .systemFont(ofSize: 12)
    keyPopup.addItems(withTitles: PlaylistFileSortKey.allCases.map(\.title))
    keyPopup.addItem(withTitle: playlistBrowserString("sort.manual"))
    keyPopup.lastItem?.isEnabled = false
    keyPopup.target = self
    keyPopup.action = #selector(changeKey)
    keyPopup.setAccessibilityLabel(playlistBrowserString("sort.label"))
    keyPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for button in [directionButton, refreshButton] {
      button.bezelStyle = .texturedRounded
      button.imagePosition = .imageOnly
      button.font = .systemFont(ofSize: 12)
      button.contentTintColor = ChengYingStyle.accent
      button.target = self
      button.translatesAutoresizingMaskIntoConstraints = false
      button.widthAnchor.constraint(equalToConstant: 28).isActive = true
      button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
    directionButton.action = #selector(changeDirection)
    refreshButton.image = ChengYingStyle.symbol("arrow.clockwise")
    refreshButton.action = #selector(refresh)
    refreshButton.toolTip = playlistBrowserString("refresh")
    refreshButton.setAccessibilityLabel(playlistBrowserString("refresh"))
    let stack = NSStackView(views: [label, keyPopup, directionButton, refreshButton])
    stack.orientation = .horizontal
    stack.spacing = 6
    stack.alignment = .centerY
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      keyPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 90)
    ])
    update(key: .name, ascending: true, manual: false, busy: false)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func update(key: PlaylistFileSortKey, ascending: Bool, manual: Bool, busy: Bool) {
    sortKey = key
    self.ascending = ascending
    let selected = manual ? PlaylistFileSortKey.allCases.count :
      PlaylistFileSortKey.allCases.firstIndex(of: key)!
    keyPopup.selectItem(at: selected)
    let direction = playlistBrowserString(ascending ? "sort.ascending" : "sort.descending")
    directionButton.image = ChengYingStyle.symbol(ascending ? "arrow.up" : "arrow.down")
    directionButton.toolTip = direction
    directionButton.setAccessibilityLabel(direction)
    directionButton.setAccessibilityValue(ascending ? 1 : 0)
    refreshButton.isEnabled = !busy
    refreshButton.toolTip = playlistBrowserString(busy ? "refresh.busy" : "refresh")
    keyPopup.toolTip = manual ? playlistBrowserString("sort.manual") : "\(key.title) · \(direction)"
  }

  @objc private func changeKey() {
    guard PlaylistFileSortKey.allCases.indices.contains(keyPopup.indexOfSelectedItem) else { return }
    sortKey = PlaylistFileSortKey.allCases[keyPopup.indexOfSelectedItem]
    onSortChange?(sortKey, ascending)
  }

  @objc private func changeDirection() {
    ascending.toggle()
    onSortChange?(sortKey, ascending)
  }

  @objc private func refresh() { onRefresh?() }
}

/// Finder colors come from their stored label indices, never from tag names.
final class PlaylistTagListView: NSView {
  private(set) var tags: [PlaylistFileTag] = []

  func setTags(_ tags: [PlaylistFileTag]) {
    self.tags = tags
    let description = tags.map(\.name).joined(separator: ", ")
    toolTip = description.isEmpty ? nil : description
    setAccessibilityElement(!tags.isEmpty)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel(description)
    needsDisplay = true
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    let font = NSFont.systemFont(ofSize: 10)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
    let colors = NSWorkspace.shared.fileLabelColors
    var x: CGFloat = 0
    for (index, tag) in tags.enumerated() {
      let label = tag.name as NSString
      let textWidth = ceil(label.size(withAttributes: attributes).width)
      let width = min(textWidth + 20, max(0, bounds.width - x))
      let remaining = tags.count - index - 1
      let suffix = remaining > 0 ? "+\(remaining)" : ""
      let suffixWidth = remaining > 0 ? ceil((suffix as NSString).size(withAttributes: attributes).width) + 8 : 0
      let available = bounds.width - x - suffixWidth
      guard available >= 20 else {
        let count = "+\(tags.count - index)" as NSString
        count.draw(in: NSRect(x: x, y: 0, width: max(0, bounds.width - x), height: bounds.height),
                   withAttributes: attributes)
        break
      }
      let displayedWidth = min(width, available)
      let dot = NSRect(x: x, y: (bounds.height - 7) / 2, width: 7, height: 7)
      let path = NSBezierPath(ovalIn: dot)
      if tag.colorIndex > 0 && tag.colorIndex < colors.count {
        colors[tag.colorIndex].setFill()
        path.fill()
      } else {
        NSColor.secondaryLabelColor.setStroke()
        path.lineWidth = 1
        path.stroke()
      }
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byTruncatingTail
      var labelAttributes = attributes
      labelAttributes[.paragraphStyle] = paragraph
      label.draw(in: NSRect(x: x + 11, y: 0, width: max(0, displayedWidth - 15), height: bounds.height),
                 withAttributes: labelAttributes)
      x += displayedWidth + 5
      if displayedWidth < width && remaining > 0 {
        (suffix as NSString).draw(in: NSRect(x: x, y: 0, width: max(0, bounds.width - x), height: bounds.height),
                                 withAttributes: attributes)
        break
      }
    }
  }
}
