import Cocoa

/// The menu owns one media generation and one filesystem snapshot, never a live URL lookup.
final class PlaybackFileTagController: NSObject {
  struct Owner: Equatable {
    let url: URL
    let generation: UInt64
  }

  private final class Choice: NSObject {
    let owner: Owner
    let snapshot: PlaybackFileTags.Snapshot
    let mutation: PlaybackFileTags.Mutation

    init(owner: Owner, snapshot: PlaybackFileTags.Snapshot, mutation: PlaybackFileTags.Mutation) {
      self.owner = owner
      self.snapshot = snapshot
      self.mutation = mutation
    }
  }

  private let currentOwner: () -> Owner?
  private let beginInteraction: () -> (() -> Void)
  private let present: (String) -> Void
  private var loading = false
  private var writing = false
  private static let colorOrder = [6, 7, 5, 2, 4, 3, 1]

  init(currentOwner: @escaping () -> Owner?, beginInteraction: @escaping () -> (() -> Void),
       present: @escaping (String) -> Void) {
    self.currentOwner = currentOwner
    self.beginInteraction = beginInteraction
    self.present = present
  }

  static func text(_ key: String, _ fallback: String) -> String {
    NSLocalizedString("file-tags." + key, tableName: "PlaylistBrowser", bundle: .main,
                      value: fallback, comment: "Current media Finder tags")
  }

  static var title: String { text("title", "Finder Color Tags") }

  func showMenu(from anchor: NSView) {
    precondition(Thread.isMainThread)
    guard !loading, !writing else { present(Self.text("busy", "The previous tag operation is still running.")); return }
    guard let owner = currentOwner(), owner.url.isFileURL else {
      present(Self.text("unavailable", "Open a local video to edit its Finder tags."))
      return
    }
    loading = true
    let finishInteraction = beginInteraction()
    PlaybackFileTags.read(url: owner.url) { [self, weak anchor] result in
      defer { loading = false; finishInteraction() }
      guard currentOwner() == owner, let anchor, anchor.window?.isVisible == true,
            !anchor.isHiddenOrHasHiddenAncestor else { return }
      switch result {
      case .success(let snapshot):
        makeMenu(snapshot: snapshot, owner: owner)
          .popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.minY - 4), in: anchor)
      case .failure(let error): present(Self.errorMessage(error))
      }
    }
  }

  func makeMenu(snapshot: PlaybackFileTags.Snapshot, owner: Owner) -> NSMenu {
    precondition(Thread.isMainThread)
    let menu = NSMenu(title: Self.title)
    menu.autoenablesItems = false
    for color in Self.colorOrder {
      let name = PlaylistTagFilter.color(color).title
      let item = NSMenuItem(title: String(format: Self.text("add", "Add %@ Tag"), name),
                            action: #selector(choose(_:)), keyEquivalent: "")
      item.target = self
      item.image = Self.colorImage(color)
      item.state = snapshot.colors.contains(color) ? .on : .off
      item.isEnabled = !snapshot.colors.contains(color)
      item.representedObject = Choice(owner: owner, snapshot: snapshot, mutation: .addColor(color, name: name))
      menu.addItem(item)
    }
    if !snapshot.tags.isEmpty {
      menu.addItem(.separator())
      let heading = NSMenuItem(title: Self.text("existing", "Existing Tags — Click to Remove"),
                               action: nil, keyEquivalent: "")
      heading.isEnabled = false
      menu.addItem(heading)
      for tag in snapshot.tags {
        let visibleName = Self.visibleName(tag.name)
        let item = NSMenuItem(title: String(format: Self.text("remove", "Remove “%@”"), visibleName),
                              action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.image = Self.colorImage(tag.colorIndex)
        item.representedObject = Choice(owner: owner, snapshot: snapshot, mutation: .removeTag(tag))
        menu.addItem(item)
      }
    }
    if let legacy = snapshot.legacyColor, (1...7).contains(legacy) {
      menu.addItem(.separator())
      let item = NSMenuItem(title: String(format: Self.text("legacy", "Preserved legacy Finder label: %@"),
                                         PlaylistTagFilter.color(legacy).title), action: nil, keyEquivalent: "")
      item.isEnabled = false
      item.image = Self.colorImage(legacy)
      menu.addItem(item)
    }
    return menu
  }

  @objc private func choose(_ sender: NSMenuItem) {
    precondition(Thread.isMainThread)
    guard sender.isEnabled, let choice = sender.representedObject as? Choice else { return }
    guard currentOwner() == choice.owner else {
      present(Self.text("changed", "The video changed. Open its tag menu again."))
      return
    }
    guard !writing, let activity = UpdateWorkAdmission.shared.beginActivity(reason: "busy.files") else {
      present(Self.text("busy", "The previous tag operation is still running."))
      return
    }
    writing = true
    PlaybackFileTags.apply(choice.mutation, to: choice.snapshot) { [self] result in
      defer { writing = false; UpdateWorkAdmission.shared.endActivity(activity) }
      switch result {
      case .success(let updated):
        NotificationCenter.default.post(name: .playbackFileTagsChanged, object: self,
                                        userInfo: ["url": updated.url])
        if currentOwner() == choice.owner { present(Self.text("saved", "Finder tags updated.")) }
      case .failure(let error):
        if currentOwner() == choice.owner { present(Self.errorMessage(error)) }
      }
    }
  }

  private static func errorMessage(_ error: PlaybackFileTags.TagError) -> String {
    let explanation: String
    switch error {
    case .unsupportedURL: explanation = "Only local files support Finder tags."
    case .unsupportedFile: explanation = "This item is not a supported regular file."
    case .changed: explanation = "The file or its tags changed. Open the tag menu again."
    case .invalidMetadata: explanation = "Existing tag metadata cannot be safely edited."
    case .metadataTooLarge: explanation = "Existing tag metadata is too large to safely edit."
    case .invalidTag: explanation = "The selected tag is invalid."
    case .nameConflict: explanation = "A different existing tag already uses this name. Rename it in Finder before adding this color."
    case .permissionDenied: explanation = "Permission to edit this file was denied. Check its Finder permissions."
    case .readOnly: explanation = "The file is on a read-only volume."
    case .unavailable: explanation = "The file or tag metadata is unavailable."
    case .writeUnverified: explanation = "The tag change could not be verified. Refresh Finder before retrying."
    }
    return String(format: text("failed", "Cannot update Finder tags: %@"),
                  text("error." + error.rawValue, explanation))
  }

  private static func colorImage(_ index: Int) -> NSImage {
    NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
      let dot = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 10, height: 10))
      let colors = NSWorkspace.shared.fileLabelColors
      if index > 0 && index < colors.count { colors[index].setFill(); dot.fill() }
      NSColor.secondaryLabelColor.setStroke()
      dot.lineWidth = 1
      dot.stroke()
      return true
    }
  }

  private static func visibleName(_ name: String) -> String {
    let cleaned = String(name.unicodeScalars.map {
      CharacterSet.controlCharacters.contains($0) ? " " : String($0)
    }.joined())
    return cleaned.count > 120 ? String(cleaned.prefix(120)) + "…" : cleaned
  }
}
