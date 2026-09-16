//
//  InitialWindowController.swift
//  iina
//
//  Created by lhc on 27/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

private func welcomeString(_ key: String) -> String {
  NSLocalizedString(key, tableName: "InitialWindowController", comment: "Welcome window")
}

private func welcomeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                          color: NSColor = .labelColor) -> NSTextField {
  let label = NSTextField(labelWithString: text)
  label.font = .systemFont(ofSize: size, weight: weight)
  label.textColor = color
  label.translatesAutoresizingMaskIntoConstraints = false
  return label
}

private final class WelcomeBackdropView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    ChengYingStyle.surface.setFill()
    bounds.fill()
    let glow = NSGradient(starting: ChengYingStyle.accent.withAlphaComponent(0.075),
                          ending: ChengYingStyle.accent.withAlphaComponent(0))
    glow?.draw(in: bounds, angle: -35)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

private final class WelcomeRecentRow: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    guard selectionHighlightStyle != .none else { return }
    ChengYingStyle.accent.withAlphaComponent(0.13).setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10).fill()
  }
}

private final class WelcomeRecentCell: NSTableCellView {
  private let filename = welcomeLabel("", size: 13, weight: .medium)
  private let folder = welcomeLabel("", size: 11, color: .secondaryLabelColor)
  private let fileIcon = NSImageView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    fileIcon.image = ChengYingStyle.symbol("film", fallback: NSImage.multipleDocumentsName)
    fileIcon.contentTintColor = ChengYingStyle.accent
    fileIcon.translatesAutoresizingMaskIntoConstraints = false
    filename.lineBreakMode = .byTruncatingMiddle
    folder.lineBreakMode = .byTruncatingMiddle
    filename.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    [fileIcon, filename, folder].forEach(addSubview)
    NSLayoutConstraint.activate([
      fileIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      fileIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
      fileIcon.widthAnchor.constraint(equalToConstant: 22),
      fileIcon.heightAnchor.constraint(equalToConstant: 22),
      filename.leadingAnchor.constraint(equalTo: fileIcon.trailingAnchor, constant: 12),
      filename.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      filename.topAnchor.constraint(equalTo: topAnchor, constant: 9),
      folder.leadingAnchor.constraint(equalTo: filename.leadingAnchor),
      folder.trailingAnchor.constraint(equalTo: filename.trailingAnchor),
      folder.topAnchor.constraint(equalTo: filename.bottomAnchor, constant: 3)
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(url: URL) {
    filename.stringValue = url.lastPathComponent
    folder.stringValue = url.deletingLastPathComponent().lastPathComponent
    toolTip = url.path
    setAccessibilityLabel("\(url.lastPathComponent), \(folder.stringValue)")
  }
}

private final class WelcomeResumeButtonCell: NSButtonCell {
  override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
    let fill = ChengYingStyle.accent.withAlphaComponent(isHighlighted ? 0.18 : 0.085)
    fill.setFill()
    let path = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
    path.fill()
    if state == .on {
      ChengYingStyle.accent.withAlphaComponent(0.5).setStroke()
      path.lineWidth = 1
      path.stroke()
    }
  }

  override func drawInterior(withFrame frame: NSRect, in controlView: NSView) {
    let lines = title.components(separatedBy: "\n")
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingMiddle
    for (index, text) in lines.prefix(3).enumerated() {
      let font = NSFont.systemFont(ofSize: index == 1 ? 13 : 10,
                                   weight: index < 2 ? .medium : .regular)
      let color: NSColor = index == 0 ? ChengYingStyle.accent :
        (index == 1 ? .labelColor : .secondaryLabelColor)
      let rect = NSRect(x: frame.minX + 16, y: frame.minY + 10 + CGFloat(index) * 19,
                        width: frame.width - 48, height: 18)
      (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color,
                                                       .paragraphStyle: paragraph])
    }
    ("›" as NSString).draw(in: NSRect(x: frame.maxX - 26, y: frame.midY - 13,
                                     width: 16, height: 26),
                           withAttributes: [.font: NSFont.systemFont(ofSize: 22),
                                            .foregroundColor: ChengYingStyle.accent])
  }
}

final class WelcomeResumeButton: NSButton {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    cell = WelcomeResumeButtonCell(textCell: "")
    setButtonType(.momentaryPushIn)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

class InitialWindowController: NSWindowController {
  override var windowNibName: NSNib.Name { NSNib.Name("InitialWindowController") }

  weak var player: PlayerCore!
  var loaded = false
  let recentFilesTableView = NSTableView()
  let primaryOpenButton = NSButton()
  let resumeButton = WelcomeResumeButton()
  private let recentScrollView = NSScrollView()
  private let recentHeading = welcomeLabel(welcomeString("welcome.recent"), size: 17, weight: .semibold)
  private let recentCount = welcomeLabel("", size: 11, weight: .medium, color: .secondaryLabelColor)
  private let emptyState = NSView()
  private var resumeHeight: NSLayoutConstraint!
  private var resumeBottomSpacing: NSLayoutConstraint!
  private var lastPlaybackURL: URL?
  private let observedPrefKeys: [Preference.Key] = [
    .themeMaterial, .recordRecentFiles, .resumeLastPosition,
    .iinaLastPlayedFilePath, .iinaLastPlayedFilePosition
  ]
  private var isObservingPreferences = false
  private let recentDocumentsProvider: () -> [URL]

  lazy var recentDocuments: [URL] = makeRecentDocumentsList()

  init(playerCore: PlayerCore,
       recentDocumentsProvider: @escaping () -> [URL] = { NSDocumentController.shared.recentDocumentURLs }) {
    self.player = playerCore
    self.recentDocumentsProvider = recentDocumentsProvider
    super.init(window: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    if isObservingPreferences {
      observedPrefKeys.forEach { UserDefaults.standard.removeObserver(self, forKeyPath: $0.rawValue) }
    }
  }

  override func windowDidLoad() {
    super.windowDidLoad()
    guard let window, let content = window.contentView else { return }
    loaded = true
    window.title = welcomeString("welcome.window_title")
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.setContentSize(NSSize(width: 900, height: 600))
    window.contentMinSize = NSSize(width: 860, height: 600)
    content.registerForDraggedTypes([.nsFilenames, .nsURL, .string])
    buildWelcomeLayout(in: content)
    setMaterial(Preference.enum(for: .themeMaterial))
    observedPrefKeys.forEach {
      UserDefaults.standard.addObserver(self, forKeyPath: $0.rawValue, options: .new, context: nil)
    }
    isObservingPreferences = true
    reloadData()
    window.initialFirstResponder = content
    window.makeFirstResponder(content)
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    if loaded { reloadData() }
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                             change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath, observedPrefKeys.contains(where: { $0.rawValue == keyPath }) else { return }
    let theme = (change?[.newKey] as? Int).flatMap(Preference.Theme.init(rawValue:))
    let update = { [weak self] in
      guard let self else { return }
      if keyPath == Preference.Key.themeMaterial.rawValue {
        self.setMaterial(theme)
      } else {
        self.reloadData()
      }
    }
    // Preference writes may originate in playback or history worker queues.
    if Thread.isMainThread {
      update()
    } else {
      DispatchQueue.main.async(execute: update)
    }
  }

  private func setMaterial(_ theme: Preference.Theme?) {
    guard let window, let theme else { return }
    window.appearance = NSAppearance(iinaTheme: theme)
    window.contentView?.needsDisplay = true
    recentFilesTableView.needsDisplay = true
  }

  private func buildWelcomeLayout(in content: NSView) {
    let backdrop = WelcomeBackdropView()
    backdrop.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(backdrop)
    NSLayoutConstraint.activate([
      backdrop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      backdrop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      backdrop.topAnchor.constraint(equalTo: content.topAnchor),
      backdrop.bottomAnchor.constraint(equalTo: content.bottomAnchor)
    ])

    let hero = makeHero()
    let library = makeLibrary()
    [hero, library].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      backdrop.addSubview($0)
    }
    NSLayoutConstraint.activate([
      hero.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 42),
      hero.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 68),
      hero.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -32),
      hero.widthAnchor.constraint(equalToConstant: 328),
      library.leadingAnchor.constraint(equalTo: hero.trailingAnchor, constant: 34),
      library.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -32),
      library.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 58),
      library.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -32)
    ])
  }

  private func makeHero() -> NSView {
    let hero = NSView()
    let icon = NSImageView()
    icon.image = NSImage(named: "iina_arrow") ?? NSApplication.shared.applicationIconImage
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.unregisterDraggedTypes()
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.setAccessibilityLabel(welcomeString("welcome.brand"))
    let brand = welcomeLabel(welcomeString("welcome.brand"), size: 27, weight: .semibold)
    let eyebrow = welcomeLabel(welcomeString("welcome.eyebrow"), size: 11, weight: .medium,
                               color: .secondaryLabelColor)
    let title = welcomeLabel(welcomeString("welcome.headline"), size: 30, weight: .semibold)
    title.maximumNumberOfLines = 2
    title.cell?.wraps = true
    let description = welcomeLabel(welcomeString("welcome.description"), size: 13,
                                    color: .secondaryLabelColor)
    description.maximumNumberOfLines = 3
    description.cell?.wraps = true

    primaryOpenButton.identifier = NSUserInterfaceItemIdentifier("welcome.open")
    primaryOpenButton.title = welcomeString("welcome.open")
    primaryOpenButton.image = ChengYingStyle.symbol("folder.badge.plus", fallback: NSImage.folderName)
    primaryOpenButton.imagePosition = .imageLeading
    primaryOpenButton.target = self
    primaryOpenButton.action = #selector(openLocalFile)
    primaryOpenButton.keyEquivalent = "o"
    primaryOpenButton.keyEquivalentModifierMask = [.command]
    primaryOpenButton.translatesAutoresizingMaskIntoConstraints = false
    ChengYingStyle.primaryButton(primaryOpenButton)
    let dragHint = welcomeLabel(welcomeString("welcome.drop"), size: 11, color: .secondaryLabelColor)
    let features = makeFeatures()
    let privacy = welcomeLabel(welcomeString("welcome.privacy"), size: 10, color: .tertiaryLabelColor)
    let info = InfoDictionary.shared
    let version = info.version.0
    let build = info.buildType == .release ? "" : " · \(info.buildType.description)"
    let versionLabel = welcomeLabel("ChengYing  \(version)\(build)", size: 10, color: .tertiaryLabelColor)

    [icon, brand, eyebrow, title, description, primaryOpenButton, dragHint, features, privacy, versionLabel]
      .forEach(hero.addSubview)
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
      icon.topAnchor.constraint(equalTo: hero.topAnchor),
      icon.widthAnchor.constraint(equalToConstant: 66),
      icon.heightAnchor.constraint(equalToConstant: 66),
      brand.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
      brand.topAnchor.constraint(equalTo: icon.topAnchor, constant: 8),
      eyebrow.leadingAnchor.constraint(equalTo: brand.leadingAnchor),
      eyebrow.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 5),
      title.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
      title.trailingAnchor.constraint(equalTo: hero.trailingAnchor),
      title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 32),
      description.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
      description.trailingAnchor.constraint(equalTo: hero.trailingAnchor),
      description.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
      primaryOpenButton.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
      primaryOpenButton.trailingAnchor.constraint(equalTo: hero.trailingAnchor),
      primaryOpenButton.topAnchor.constraint(equalTo: description.bottomAnchor, constant: 26),
      primaryOpenButton.heightAnchor.constraint(equalToConstant: 46),
      dragHint.centerXAnchor.constraint(equalTo: primaryOpenButton.centerXAnchor),
      dragHint.topAnchor.constraint(equalTo: primaryOpenButton.bottomAnchor, constant: 10),
      features.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
      features.trailingAnchor.constraint(equalTo: hero.trailingAnchor),
      features.topAnchor.constraint(equalTo: dragHint.bottomAnchor, constant: 26),
      privacy.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
      privacy.bottomAnchor.constraint(equalTo: versionLabel.topAnchor, constant: -6),
      versionLabel.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
      versionLabel.bottomAnchor.constraint(equalTo: hero.bottomAnchor)
    ])
    return hero
  }

  private func makeFeatures() -> NSView {
    let rows = [
      [("scissors", "welcome.feature.trim"), ("rectangle.stack", "welcome.feature.frames")],
      [("rotate.right", "welcome.feature.rotate"), ("captions.bubble", "welcome.feature.subtitle")]
    ].map { entries in
      entries.map { symbol, key -> NSView in
        let image = NSImageView(image: ChengYingStyle.symbol(symbol))
        image.contentTintColor = .secondaryLabelColor
        image.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [image, welcomeLabel(welcomeString(key), size: 11,
                                                       color: .secondaryLabelColor)])
        row.orientation = .horizontal
        row.spacing = 7
        image.widthAnchor.constraint(equalToConstant: 15).isActive = true
        image.heightAnchor.constraint(equalToConstant: 15).isActive = true
        return row
      }
    }
    let grid = NSGridView(views: rows)
    grid.translatesAutoresizingMaskIntoConstraints = false
    grid.rowSpacing = 12
    grid.columnSpacing = 24
    return grid
  }

  private func makeLibrary() -> NSView {
    let body = NSView()
    recentCount.alignment = .right
    let divider = NSBox()
    divider.boxType = .separator
    divider.translatesAutoresizingMaskIntoConstraints = false

    resumeButton.identifier = NSUserInterfaceItemIdentifier("welcome.resume")
    resumeButton.target = self
    resumeButton.action = #selector(resumeLastPlayback)
    resumeButton.alignment = .left
    resumeButton.cell?.wraps = true
    resumeButton.cell?.lineBreakMode = .byTruncatingMiddle
    resumeButton.translatesAutoresizingMaskIntoConstraints = false
    ChengYingStyle.secondaryButton(resumeButton)

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recentFile"))
    column.resizingMask = .autoresizingMask
    recentFilesTableView.addTableColumn(column)
    recentFilesTableView.headerView = nil
    recentFilesTableView.rowHeight = 54
    recentFilesTableView.intercellSpacing = NSSize(width: 0, height: 2)
    recentFilesTableView.backgroundColor = .clear
    if #available(macOS 11.0, *) { recentFilesTableView.style = .plain }
    recentFilesTableView.selectionHighlightStyle = .regular
    recentFilesTableView.allowsMultipleSelection = false
    recentFilesTableView.allowsColumnReordering = false
    recentFilesTableView.delegate = self
    recentFilesTableView.dataSource = self
    recentFilesTableView.target = self
    recentFilesTableView.action = #selector(onTableClicked)
    recentFilesTableView.setAccessibilityLabel(welcomeString("welcome.recent"))
    recentScrollView.documentView = recentFilesTableView
    recentScrollView.drawsBackground = false
    recentScrollView.hasVerticalScroller = true
    recentScrollView.autohidesScrollers = true
    recentScrollView.borderType = .noBorder
    recentScrollView.translatesAutoresizingMaskIntoConstraints = false
    let keyHint = welcomeLabel(welcomeString("welcome.keyboard"), size: 10,
                              color: .tertiaryLabelColor)
    keyHint.alignment = .right
    configureEmptyState()

    [recentHeading, recentCount, divider, resumeButton, recentScrollView, emptyState, keyHint]
      .forEach(body.addSubview)
    resumeHeight = resumeButton.heightAnchor.constraint(equalToConstant: 76)
    resumeBottomSpacing = recentScrollView.topAnchor.constraint(equalTo: resumeButton.bottomAnchor,
                                                               constant: 12)
    NSLayoutConstraint.activate([
      recentHeading.leadingAnchor.constraint(equalTo: body.leadingAnchor),
      recentHeading.topAnchor.constraint(equalTo: body.topAnchor, constant: 2),
      recentCount.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      recentCount.centerYAnchor.constraint(equalTo: recentHeading.centerYAnchor),
      divider.leadingAnchor.constraint(equalTo: body.leadingAnchor),
      divider.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      divider.topAnchor.constraint(equalTo: recentHeading.bottomAnchor, constant: 18),
      resumeButton.leadingAnchor.constraint(equalTo: body.leadingAnchor),
      resumeButton.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      resumeButton.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 16),
      resumeHeight,
      resumeBottomSpacing,
      recentScrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
      recentScrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      recentScrollView.bottomAnchor.constraint(equalTo: keyHint.topAnchor, constant: -12),
      keyHint.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      keyHint.bottomAnchor.constraint(equalTo: body.bottomAnchor),
      emptyState.leadingAnchor.constraint(equalTo: recentScrollView.leadingAnchor),
      emptyState.trailingAnchor.constraint(equalTo: recentScrollView.trailingAnchor),
      emptyState.topAnchor.constraint(equalTo: recentScrollView.topAnchor),
      emptyState.bottomAnchor.constraint(equalTo: recentScrollView.bottomAnchor)
    ])
    return ChengYingStyle.card(body, insets: NSEdgeInsets(top: 24, left: 22, bottom: 18, right: 22))
  }

  private func configureEmptyState() {
    emptyState.identifier = NSUserInterfaceItemIdentifier("welcome.empty")
    emptyState.translatesAutoresizingMaskIntoConstraints = false
    let image = NSImageView(image: ChengYingStyle.symbol("play.rectangle", fallback: NSImage.multipleDocumentsName))
    image.contentTintColor = .tertiaryLabelColor
    image.imageScaling = .scaleProportionallyUpOrDown
    image.translatesAutoresizingMaskIntoConstraints = false
    let title = welcomeLabel(welcomeString("welcome.empty.title"), size: 15, weight: .medium)
    let hint = welcomeLabel(welcomeString("welcome.empty.hint"), size: 12, color: .secondaryLabelColor)
    hint.maximumNumberOfLines = 3
    hint.cell?.wraps = true
    hint.alignment = .center
    [image, title, hint].forEach(emptyState.addSubview)
    NSLayoutConstraint.activate([
      image.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
      image.centerYAnchor.constraint(equalTo: emptyState.centerYAnchor, constant: -38),
      image.widthAnchor.constraint(equalToConstant: 48),
      image.heightAnchor.constraint(equalToConstant: 40),
      title.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
      title.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 18),
      hint.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
      hint.leadingAnchor.constraint(greaterThanOrEqualTo: emptyState.leadingAnchor, constant: 24),
      hint.trailingAnchor.constraint(lessThanOrEqualTo: emptyState.trailingAnchor, constant: -24),
      hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 9)
    ])
  }

  private func makeRecentDocumentsList() -> [URL] {
    guard Preference.bool(for: .recordRecentFiles) else { return [] }
    return recentDocumentsProvider().filter {
      $0.isFileURL && $0.resolvingSymlinksInPath() != lastPlaybackURL?.resolvingSymlinksInPath()
    }
  }

  func loadLastPlaybackInfo() {
    if Preference.bool(for: .recordRecentFiles),
       Preference.bool(for: .resumeLastPosition),
       let lastFile = Preference.url(for: .iinaLastPlayedFilePath),
       lastFile.isFileURL, FileManager.default.fileExists(atPath: lastFile.path) {
      lastPlaybackURL = lastFile
      let position = VideoTime(Preference.double(for: .iinaLastPlayedFilePosition)).stringRepresentation
      resumeButton.title = String(format: welcomeString("welcome.resume"), lastFile.lastPathComponent, position)
      resumeButton.toolTip = lastFile.path
      resumeButton.setAccessibilityLabel(resumeButton.title)
      resumeButton.isHidden = false
      resumeHeight.constant = 76
      resumeBottomSpacing.constant = 12
    } else {
      lastPlaybackURL = nil
      resumeButton.isHidden = true
      resumeHeight.constant = 0
      resumeBottomSpacing.constant = 0
    }
  }

  func reloadData() {
    guard loaded else { return }
    loadLastPlaybackInfo()
    recentDocuments = makeRecentDocumentsList()
    recentFilesTableView.reloadData()
    recentCount.stringValue = recentDocuments.isEmpty ? "" : String(recentDocuments.count)
    emptyState.isHidden = !recentDocuments.isEmpty || lastPlaybackURL != nil
    recentScrollView.isHidden = recentDocuments.isEmpty
    if lastPlaybackURL == nil && !recentDocuments.isEmpty {
      recentFilesTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    } else {
      recentFilesTableView.deselectAll(nil)
    }
    updateLastFileButtonHighlight()
  }

  @objc func openLocalFile() { AppDelegate.shared.openFile(self) }

  @objc func resumeLastPlayback() {
    guard let url = lastPlaybackURL else { return }
    player.openURL(url)
  }

  @objc func onTableClicked() { openRecentItemFromTable(recentFilesTableView.clickedRow) }

  private func openRecentItemFromTable(_ row: Int) {
    guard let url = recentDocuments[at: row] else { return }
    player.openURL(url)
  }

  func updateLastFileButtonHighlight() {
    resumeButton.state = recentFilesTableView.selectedRow < 0 && lastPlaybackURL != nil ? .on : .off
    resumeButton.needsDisplay = true
  }

  override func keyDown(with event: NSEvent) {
    let key = KeyCodeHelper.keyMap[event.keyCode]?.0
    switch key {
    case "ENTER", "KP_ENTER":
      if recentFilesTableView.selectedRow >= 0 {
        openRecentItemFromTable(recentFilesTableView.selectedRow)
      } else if lastPlaybackURL != nil {
        resumeLastPlayback()
      } else if !recentDocuments.isEmpty {
        openRecentItemFromTable(0)
      }
    case "DOWN":
      let next = recentFilesTableView.selectedRow + 1
      if next < recentDocuments.count {
        recentFilesTableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        recentFilesTableView.scrollRowToVisible(next)
      } else {
        super.keyDown(with: event)
      }
    case "UP":
      let previous = recentFilesTableView.selectedRow - 1
      if previous >= 0 {
        recentFilesTableView.selectRowIndexes(IndexSet(integer: previous), byExtendingSelection: false)
        recentFilesTableView.scrollRowToVisible(previous)
      } else if lastPlaybackURL != nil {
        recentFilesTableView.deselectAll(nil)
      } else {
        super.keyDown(with: event)
      }
    default:
      super.keyDown(with: event)
    }
  }
}

extension InitialWindowController: NSTableViewDelegate, NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int { recentDocuments.count }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    WelcomeRecentRow()
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier("welcome.recentCell")
    let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? WelcomeRecentCell ??
      WelcomeRecentCell()
    cell.identifier = identifier
    cell.configure(url: recentDocuments[row])
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) { updateLastFileButtonHighlight() }
}

class InitialWindowContentView: NSView {
  override var acceptsFirstResponder: Bool { true }

  var player: PlayerCore? { (window?.windowController as? InitialWindowController)?.player }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    player?.acceptFromPasteboard(sender) ?? []
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    player?.openFromPasteboard(sender) ?? false
  }
}
