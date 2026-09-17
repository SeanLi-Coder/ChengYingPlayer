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

class InitialWindowController: NSWindowController {
  override var windowNibName: NSNib.Name { NSNib.Name("InitialWindowController") }

  weak var player: PlayerCore!
  var loaded = false
  let primaryOpenButton = NSButton()
  let downloadCenterButton = NSButton()
  let fileAccessButton = NSButton()
  private let observedPrefKeys: [Preference.Key] = [.themeMaterial]
  private var isObservingPreferences = false

  init(playerCore: PlayerCore) {
    self.player = playerCore
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
    window.setContentSize(NSSize(width: 580, height: 620))
    window.contentMinSize = NSSize(width: 560, height: 600)
    content.registerForDraggedTypes([.nsFilenames, .nsURL, .string])
    buildWelcomeLayout(in: content)
    setMaterial(Preference.enum(for: .themeMaterial))
    observedPrefKeys.forEach {
      UserDefaults.standard.addObserver(self, forKeyPath: $0.rawValue, options: .new, context: nil)
    }
    isObservingPreferences = true
    window.initialFirstResponder = content
    window.makeFirstResponder(content)
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                             change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath, observedPrefKeys.contains(where: { $0.rawValue == keyPath }) else { return }
    let theme = (change?[.newKey] as? Int).flatMap(Preference.Theme.init(rawValue:))
    let update: () -> Void = { [weak self] in
      self?.setMaterial(theme)
    }
    // Theme changes may arrive from a background preference update.
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
    hero.translatesAutoresizingMaskIntoConstraints = false
    backdrop.addSubview(hero)
    NSLayoutConstraint.activate([
      hero.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
      hero.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 58),
      hero.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -28),
      hero.widthAnchor.constraint(equalToConstant: 440),
      hero.leadingAnchor.constraint(greaterThanOrEqualTo: backdrop.leadingAnchor, constant: 40),
      hero.trailingAnchor.constraint(lessThanOrEqualTo: backdrop.trailingAnchor, constant: -40)
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
    let brandText = NSView()
    brandText.translatesAutoresizingMaskIntoConstraints = false
    brandText.addSubview(brand)
    brandText.addSubview(eyebrow)
    // Give both localized labels explicit edges without nested stack gravity constraints.
    let brandTextWidth = ceil(max(brand.intrinsicContentSize.width, eyebrow.intrinsicContentSize.width))
    NSLayoutConstraint.activate([
      brandText.widthAnchor.constraint(equalToConstant: brandTextWidth),
      brand.leadingAnchor.constraint(equalTo: brandText.leadingAnchor),
      brand.trailingAnchor.constraint(equalTo: brandText.trailingAnchor),
      brand.topAnchor.constraint(equalTo: brandText.topAnchor),
      eyebrow.leadingAnchor.constraint(equalTo: brandText.leadingAnchor),
      eyebrow.trailingAnchor.constraint(equalTo: brandText.trailingAnchor),
      eyebrow.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 5),
      eyebrow.bottomAnchor.constraint(equalTo: brandText.bottomAnchor)
    ])
    let header = NSStackView(views: [icon, brandText])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 14
    header.translatesAutoresizingMaskIntoConstraints = false
    let title = welcomeLabel(welcomeString("welcome.headline"), size: 30, weight: .semibold)
    title.alignment = .center
    title.maximumNumberOfLines = 2
    title.cell?.wraps = true
    let description = welcomeLabel(welcomeString("welcome.description"), size: 13,
                                    color: .secondaryLabelColor)
    description.alignment = .center
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
    downloadCenterButton.identifier = NSUserInterfaceItemIdentifier("welcome.download")
    downloadCenterButton.title = welcomeString("welcome.download")
    downloadCenterButton.image = ChengYingStyle.symbol("arrow.down.circle")
    downloadCenterButton.imagePosition = .imageLeading
    downloadCenterButton.target = self
    downloadCenterButton.action = #selector(openDownloadCenter)
    downloadCenterButton.translatesAutoresizingMaskIntoConstraints = false
    ChengYingStyle.secondaryButton(downloadCenterButton)
    let dragHint = welcomeLabel(welcomeString("welcome.drop"), size: 11, color: .secondaryLabelColor)
    let features = makeFeatures()
    let privacy = welcomeLabel(welcomeString("welcome.privacy"), size: 10, color: .tertiaryLabelColor)
    let info = InfoDictionary.shared
    let version = info.version.0
    let build = info.buildType == .release ? "" : " · \(info.buildType.description)"
    let versionLabel = welcomeLabel("ChengYing View  \(version)\(build)", size: 10, color: .tertiaryLabelColor)

    fileAccessButton.title = welcomeString("welcome.file_access")
    fileAccessButton.identifier = NSUserInterfaceItemIdentifier("welcome.file_access")
    fileAccessButton.isBordered = false
    fileAccessButton.font = .systemFont(ofSize: 11)
    fileAccessButton.contentTintColor = ChengYingStyle.accent
    fileAccessButton.target = self
    fileAccessButton.action = #selector(openFileAccessGuide)
    fileAccessButton.translatesAutoresizingMaskIntoConstraints = false

    [header, title, description, primaryOpenButton, downloadCenterButton, dragHint, features, fileAccessButton, privacy, versionLabel]
      .forEach(hero.addSubview)
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 66),
      icon.heightAnchor.constraint(equalToConstant: 66),
      header.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
      header.topAnchor.constraint(equalTo: hero.topAnchor),
      header.leadingAnchor.constraint(greaterThanOrEqualTo: hero.leadingAnchor),
      header.trailingAnchor.constraint(lessThanOrEqualTo: hero.trailingAnchor),
      title.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
      title.trailingAnchor.constraint(equalTo: hero.trailingAnchor),
      title.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
      description.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
      description.trailingAnchor.constraint(equalTo: hero.trailingAnchor),
      description.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
      primaryOpenButton.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
      primaryOpenButton.trailingAnchor.constraint(equalTo: hero.trailingAnchor),
      primaryOpenButton.topAnchor.constraint(equalTo: description.bottomAnchor, constant: 22),
      primaryOpenButton.heightAnchor.constraint(equalToConstant: 46),
      downloadCenterButton.leadingAnchor.constraint(equalTo: primaryOpenButton.leadingAnchor),
      downloadCenterButton.trailingAnchor.constraint(equalTo: primaryOpenButton.trailingAnchor),
      downloadCenterButton.topAnchor.constraint(equalTo: primaryOpenButton.bottomAnchor, constant: 8),
      downloadCenterButton.heightAnchor.constraint(equalToConstant: 36),
      dragHint.centerXAnchor.constraint(equalTo: primaryOpenButton.centerXAnchor),
      dragHint.leadingAnchor.constraint(greaterThanOrEqualTo: hero.leadingAnchor),
      dragHint.trailingAnchor.constraint(lessThanOrEqualTo: hero.trailingAnchor),
      dragHint.topAnchor.constraint(equalTo: downloadCenterButton.bottomAnchor, constant: 10),
      features.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
      features.leadingAnchor.constraint(greaterThanOrEqualTo: hero.leadingAnchor),
      features.trailingAnchor.constraint(lessThanOrEqualTo: hero.trailingAnchor),
      features.topAnchor.constraint(equalTo: dragHint.bottomAnchor, constant: 22),
      features.bottomAnchor.constraint(lessThanOrEqualTo: fileAccessButton.topAnchor, constant: -16),
      fileAccessButton.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
      fileAccessButton.leadingAnchor.constraint(greaterThanOrEqualTo: hero.leadingAnchor),
      fileAccessButton.trailingAnchor.constraint(lessThanOrEqualTo: hero.trailingAnchor),
      fileAccessButton.bottomAnchor.constraint(equalTo: privacy.topAnchor, constant: -10),
      privacy.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
      privacy.leadingAnchor.constraint(greaterThanOrEqualTo: hero.leadingAnchor),
      privacy.trailingAnchor.constraint(lessThanOrEqualTo: hero.trailingAnchor),
      privacy.bottomAnchor.constraint(equalTo: versionLabel.topAnchor, constant: -6),
      versionLabel.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
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

  @objc private func openDownloadCenter() {
    NSApp.sendAction(NSSelectorFromString("menuShowDownloadCenter:"), to: NSApp.delegate, from: self)
  }

  @objc private func openFileAccessGuide() {
    NSApp.sendAction(NSSelectorFromString("showFileAccessGuide:"), to: NSApp.delegate, from: self)
  }

  @objc func openLocalFile() { AppDelegate.shared.openFile(self) }

  override func keyDown(with event: NSEvent) {
    let key = KeyCodeHelper.keyMap[event.keyCode]?.0
    switch key {
    case "ENTER", "KP_ENTER":
      openLocalFile()
    default:
      super.keyDown(with: event)
    }
  }
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
