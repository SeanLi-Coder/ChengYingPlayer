import Cocoa

func playlistBrowserString(_ key: String) -> String {
  NSLocalizedString(key, tableName: "PlaylistBrowser", comment: "Local playlist browser")
}

extension PlaylistFileSortKey {
  var title: String { playlistBrowserString("sort.\(rawValue)") }
}

extension PlaylistTagFilter {
  var title: String {
    let key: String
    switch self {
    case .all: key = "filter.all"
    case .untagged: key = "filter.untagged"
    case .color(let index):
      switch index {
      case 0: key = "filter.uncolored"
      case 1: key = "filter.gray"
      case 2: key = "filter.green"
      case 3: key = "filter.purple"
      case 4: key = "filter.blue"
      case 5: key = "filter.yellow"
      case 6: key = "filter.red"
      case 7: key = "filter.orange"
      default: key = "filter.all"
      }
    }
    return playlistBrowserString(key)
  }
}

/// Filters the visible file list without changing the underlying playback queue.
final class PlaylistTagFilterControls: NSView {
  let filterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  var onFilterChange: ((PlaylistTagFilter) -> Void)?
  private let countLabel = NSTextField(labelWithString: "")
  private let filters = PlaylistTagFilter.allCases

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: 38)
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    let label = NSTextField(labelWithString: playlistBrowserString("filter.label"))
    label.identifier = NSUserInterfaceItemIdentifier("playlist.tag-filter.label")
    label.font = .systemFont(ofSize: 11, weight: .medium)
    label.textColor = .secondaryLabelColor
    filterPopup.font = .systemFont(ofSize: 12)
    filterPopup.controlSize = .small
    filterPopup.target = self
    filterPopup.action = #selector(changeFilter)
    filterPopup.setAccessibilityLabel(playlistBrowserString("filter.label"))
    filterPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for filter in filters {
      filterPopup.addItem(withTitle: filter.title)
      filterPopup.lastItem?.image = Self.colorImage(for: filter)
    }
    countLabel.identifier = NSUserInterfaceItemIdentifier("playlist.tag-filter.count")
    countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    countLabel.textColor = .secondaryLabelColor
    countLabel.alignment = .right
    countLabel.lineBreakMode = .byTruncatingMiddle
    countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for view in [label, filterPopup, countLabel] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
      view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
    }
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      label.widthAnchor.constraint(equalToConstant: 50),
      filterPopup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
      filterPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
      filterPopup.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -6),
      countLabel.widthAnchor.constraint(equalToConstant: 48),
      countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
    ])
    update(filter: .all, matchingCount: 0, totalCount: 0, busy: false)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func update(filter: PlaylistTagFilter, matchingCount: Int, totalCount: Int, busy: Bool) {
    filterPopup.selectItem(at: filters.firstIndex(of: filter) ?? 0)
    // Metadata refreshes must never lock the user into their previous filter.
    filterPopup.isEnabled = true
    let total = max(0, totalCount)
    let matching = max(0, min(matchingCount, total))
    countLabel.stringValue = "\(Self.compactCount(matching))/\(Self.compactCount(total))"
    let numberFormatter = NumberFormatter()
    numberFormatter.numberStyle = .decimal
    let fullCount = String(format: playlistBrowserString("filter.count"),
                           numberFormatter.string(from: NSNumber(value: matching)) ?? String(matching),
                           numberFormatter.string(from: NSNumber(value: total)) ?? String(total))
    let status = busy ? playlistBrowserString("filter.busy") + "\n" : ""
    let explanation = status + fullCount + "\n" + playlistBrowserString("filter.scope")
    toolTip = explanation
    countLabel.toolTip = explanation
    countLabel.setAccessibilityLabel(status + fullCount)
    filterPopup.toolTip = (filterPopup.selectedItem?.title ?? filter.title) + "\n" + explanation
    filterPopup.setAccessibilityHelp(explanation)
  }

  @objc private func changeFilter() {
    guard filters.indices.contains(filterPopup.indexOfSelectedItem) else { return }
    onFilterChange?(filters[filterPopup.indexOfSelectedItem])
  }

  private static func compactCount(_ count: Int) -> String {
    guard count >= 1_000 else { return String(count) }
    let divisor: Double
    let suffix: String
    if count >= 1_000_000_000 {
      divisor = 1_000_000_000
      suffix = "B"
    } else if count >= 1_000_000 {
      divisor = 1_000_000
      suffix = "M"
    } else {
      divisor = 1_000
      suffix = "k"
    }
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 1
    formatter.usesGroupingSeparator = false
    let value = formatter.string(from: NSNumber(value: Double(count) / divisor)) ?? String(count)
    return value + suffix
  }

  private static func colorImage(for filter: PlaylistTagFilter) -> NSImage? {
    guard case .color(let index) = filter else { return nil }
    // Use the stored Finder index, including a hollow dot for uncolored tags.
    return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
      let dot = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 8, height: 8))
      let colors = NSWorkspace.shared.fileLabelColors
      if index > 0 && index < colors.count {
        colors[index].setFill()
        dot.fill()
      } else {
        NSColor.secondaryLabelColor.setStroke()
        dot.lineWidth = 1
        dot.stroke()
      }
      return true
    }
  }
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
