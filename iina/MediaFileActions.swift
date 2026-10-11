import Cocoa

extension Notification.Name {
  static let mediaFilesTransferred = Notification.Name("io.chengying.media-files-transferred")
}

/// Filesystem shortcuts belong to the focused file table, never a text field or the playback queue.
final class FileListTableView: NSTableView {
  weak var fileActions: MediaFileActions?

  override func menu(for event: NSEvent) -> NSMenu? {
    guard let fileActions else { return super.menu(for: event) }
    window?.makeFirstResponder(self)
    let clicked = row(at: convert(event.locationInWindow, from: nil))
    let rows: IndexSet
    if clicked < 0 { rows = [] }
    else if selectedRowIndexes.contains(clicked) { rows = selectedRowIndexes }
    else { rows = IndexSet(integer: clicked) }
    // Do not select the clicked row: image selection may activate another document.
    return fileActions.menu(for: rows)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.firstResponder === self, window?.isVisible == true,
          !isHiddenOrHasHiddenAncestor, let fileActions else {
      return super.performKeyEquivalent(with: event)
    }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    let key = event.charactersIgnoringModifiers?.lowercased()
    if modifiers == [.command, .option], key == "v" {
      fileActions.moveHere(nil)
      return true
    }
    if modifiers == .command {
      switch key {
      case "c": fileActions.copy(nil)
      case "x": fileActions.cut(nil)
      case "v": fileActions.paste(nil)
      default: return super.performKeyEquivalent(with: event)
      }
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  private var ownsFileFocus: Bool { window?.firstResponder === self && window?.isVisible == true && !isHiddenOrHasHiddenAncestor }

  @objc func copy(_ sender: Any?) { if ownsFileFocus { fileActions?.copy(sender) } }
  @objc func cut(_ sender: Any?) { if ownsFileFocus { fileActions?.cut(sender) } }
  @objc func paste(_ sender: Any?) { if ownsFileFocus { fileActions?.paste(sender) } }
  @objc func moveHere(_ sender: Any?) { if ownsFileFocus { fileActions?.moveHere(sender) } }

  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    switch item.action {
    case #selector(copy(_:)), #selector(cut(_:)), #selector(paste(_:)), #selector(moveHere(_:)):
      return ownsFileFocus && (fileActions?.isEnabled(action: item.action, context: nil) ?? false)
    default: return super.validateUserInterfaceItem(item)
    }
  }
}

/// File identities are captured before showing menus and before dispatching background work.
final class MediaFileActions: NSObject, NSMenuItemValidation {
  fileprivate struct Selection {
    var sources: [MediaFileTransfer.Source]
    let error: Error?
    let count: Int

    init(urls: [URL]) {
      count = urls.count
      do {
        sources = try urls.map { try MediaFileTransfer.Source(url: $0) }
        error = nil
      } catch {
        sources = []
        self.error = error
      }
    }

    init(sources: [MediaFileTransfer.Source]) {
      self.sources = sources
      error = nil
      count = sources.count
    }
  }

  fileprivate struct ClipboardSnapshot {
    let selection: Selection
    let changeCount: Int
    let marker: String?
    let isCut: Bool
  }

  fileprivate final class Context: NSObject {
    fileprivate let selection: Selection
    fileprivate let destination: MediaFileTransfer.Source?
    fileprivate let destinationError: Error?
    fileprivate let clipboard: ClipboardSnapshot

    fileprivate init(selection: Selection, destination: URL?, clipboard: ClipboardSnapshot) {
      self.selection = selection
      self.clipboard = clipboard
      do {
        self.destination = try destination.map { try MediaFileTransfer.Source(url: $0) }
        destinationError = nil
      } catch {
        self.destination = nil
        destinationError = error
      }
    }
  }

  private static let markerType = NSPasteboard.PasteboardType("io.chengying.file-transfer.intent")
  private static var ownedClipboards = [NSPasteboard.Name: ClipboardSnapshot]()
  private static let controllers = NSHashTable<MediaFileActions>.weakObjects()
  private static let queue = DispatchQueue(label: "io.chengying.file-transfer", qos: .userInitiated)
  private(set) static var pendingOperationCount = 0
  private(set) static var pendingMoveCount = 0
  private(set) var pendingOperationCount = 0
  static var additionalProtectedURLs: () -> [URL] = { [] }
  static var additionalAdmission: () -> Bool = { true }

  private weak var tableView: FileListTableView?
  private let selectedURLs: () -> [URL]
  private let URLsForRows: ((IndexSet) -> [URL])?
  private let destinationURL: () -> URL?
  private let canOperate: () -> Bool
  private let protectedURLs: () -> [URL]
  private let didTransfer: (MediaFileTransfer.Report) -> Void
  private let presentation: ((String, Bool) -> Void)?
  private let pasteboard: NSPasteboard
  private let executor: ([MediaFileTransfer.Source], MediaFileTransfer.Source,
                         MediaFileTransfer.Operation) -> MediaFileTransfer.Report
  private var isUsable: Bool {
    tableView?.window?.isVisible == true && tableView?.isHiddenOrHasHiddenAncestor == false
  }

  init(tableView: FileListTableView, selectedURLs: @escaping () -> [URL],
       URLsForRows: ((IndexSet) -> [URL])? = nil, destinationURL: @escaping () -> URL?,
       canOperate: @escaping () -> Bool = { true }, protectedURLs: @escaping () -> [URL] = { [] },
       didTransfer: @escaping (MediaFileTransfer.Report) -> Void = { _ in },
       presentation: ((String, Bool) -> Void)? = nil, pasteboard: NSPasteboard = .general,
       executor: @escaping ([MediaFileTransfer.Source], MediaFileTransfer.Source,
                            MediaFileTransfer.Operation) -> MediaFileTransfer.Report = MediaFileTransfer.execute) {
    self.tableView = tableView
    self.selectedURLs = selectedURLs
    self.URLsForRows = URLsForRows
    self.destinationURL = destinationURL
    self.canOperate = canOperate
    self.protectedURLs = protectedURLs
    self.didTransfer = didTransfer
    self.presentation = presentation
    self.pasteboard = pasteboard
    self.executor = executor
    super.init()
    tableView.fileActions = self
    Self.controllers.add(self)
  }

  func menu(for rows: IndexSet) -> NSMenu {
    precondition(Thread.isMainThread)
    let urls = rows.isEmpty ? [] : (URLsForRows?(rows) ?? selectedURLs())
    let context = Context(selection: Selection(urls: urls), destination: destinationURL(),
                          clipboard: readClipboard())
    let menu = NSMenu()
    let entries: [(String, Selector, String, NSEvent.ModifierFlags)] = [
      ("file-actions.copy", #selector(copy(_:)), "c", .command),
      ("file-actions.cut", #selector(cut(_:)), "x", .command),
      ("file-actions.paste", #selector(paste(_:)), "v", .command),
      ("file-actions.move", #selector(moveHere(_:)), "v", [.command, .option]),
    ]
    for (key, action, equivalent, modifiers) in entries {
      let item = NSMenuItem(title: Self.string(key), action: action, keyEquivalent: equivalent)
      item.keyEquivalentModifierMask = modifiers
      item.target = self
      item.representedObject = context
      item.isEnabled = isEnabled(action: action, context: context)
      menu.addItem(item)
    }
    return menu
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    isEnabled(action: menuItem.action, context: menuItem.representedObject as? Context)
  }

  fileprivate func isEnabled(action: Selector?, context: Context?) -> Bool {
    guard isUsable, canOperate(), Self.additionalAdmission(), Self.pendingOperationCount == 0,
          !UpdateWorkAdmission.shared.isBlocked else { return false }
    switch action {
    case #selector(copy(_:)), #selector(cut(_:)):
      return context.map { $0.selection.count > 0 } ?? !selectedURLs().isEmpty
    case #selector(paste(_:)), #selector(moveHere(_:)):
      if let context {
        return context.destination?.isDirectory == true && context.clipboard.selection.count > 0
      }
      return destinationURL() != nil && pasteboard.canReadObject(forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true])
    default: return false
    }
  }

  @objc func copy(_ sender: Any?) { putSelectionOnClipboard(sender, cut: false) }
  @objc func cut(_ sender: Any?) { putSelectionOnClipboard(sender, cut: true) }
  @objc func paste(_ sender: Any?) { transfer(sender, forceMove: false) }
  @objc func moveHere(_ sender: Any?) { transfer(sender, forceMove: true) }

  private func putSelectionOnClipboard(_ sender: Any?, cut: Bool) {
    precondition(Thread.isMainThread)
    guard isUsable, canOperate(), Self.additionalAdmission(), Self.pendingOperationCount == 0,
          !UpdateWorkAdmission.shared.isBlocked else {
      present(Self.string("file-actions.busy"), error: true)
      return
    }
    let context = (sender as? NSMenuItem)?.representedObject as? Context
    let selection = context?.selection ?? Selection(urls: selectedURLs())
    guard selection.count > 0 else { return }
    do {
      if let error = selection.error { throw error }
      for source in selection.sources { try source.validate() }
      try writeClipboard(selection, cut: cut)
      present(Self.string(cut ? "file-actions.cut-ready" : "file-actions.copy-ready"), error: false)
    } catch { present(error.localizedDescription, error: true) }
  }

  private func writeClipboard(_ selection: Selection, cut: Bool) throws {
    let marker = UUID().uuidString
    let items = selection.sources.enumerated().map { index, source -> NSPasteboardItem in
      let item = NSPasteboardItem()
      item.setString(source.url.absoluteString, forType: .fileURL)
      if index == 0 { item.setString(marker, forType: Self.markerType) }
      return item
    }
    // All source validation occurs before changing the clipboard.
    pasteboard.clearContents()
    guard pasteboard.writeObjects(items) else {
      Self.ownedClipboards.removeValue(forKey: pasteboard.name)
      throw Self.localError("file-actions.clipboard-error")
    }
    Self.ownedClipboards[pasteboard.name] = ClipboardSnapshot(selection: selection,
      changeCount: pasteboard.changeCount, marker: marker, isCut: cut)
  }

  private func readClipboard() -> ClipboardSnapshot {
    let count = pasteboard.changeCount
    if let owned = Self.ownedClipboards[pasteboard.name], owned.changeCount == count,
       pasteboard.string(forType: Self.markerType) == owned.marker {
      return owned
    }
    Self.ownedClipboards.removeValue(forKey: pasteboard.name)
    let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    return ClipboardSnapshot(selection: Selection(urls: urls), changeCount: count, marker: nil, isCut: false)
  }

  private func transfer(_ sender: Any?, forceMove: Bool) {
    precondition(Thread.isMainThread)
    guard isUsable, canOperate(), Self.additionalAdmission(), Self.pendingOperationCount == 0 else {
      present(Self.string("file-actions.busy"), error: true)
      return
    }
    let context = (sender as? NSMenuItem)?.representedObject as? Context
    let clipboard = context?.clipboard ?? readClipboard()
    let destinationContext = context ?? Context(selection: Selection(urls: []),
      destination: destinationURL(), clipboard: clipboard)
    guard clipboard.selection.count > 0 else { return }
    guard pasteboard.changeCount == clipboard.changeCount else {
      present(Self.string("file-actions.clipboard-changed"), error: true)
      return
    }
    if let error = clipboard.selection.error ?? destinationContext.destinationError {
      present(error.localizedDescription, error: true)
      return
    }
    guard let destination = destinationContext.destination, destination.isDirectory else {
      present(Self.string("file-actions.no-destination"), error: true)
      return
    }
    let operation: MediaFileTransfer.Operation = forceMove || clipboard.isCut ? .move : .copy
    // Freeze new playback admission before hosts snapshot their protected queues.
    // Hosts take their queue locks so any already-admitted append is included.
    guard let activity = UpdateWorkAdmission.shared.beginActivity(
      reason: operation == .move ? "busy.fileMove" : "busy.files") else {
      present(Self.string("file-actions.busy"), error: true)
      return
    }
    let protected = operation == .move
      ? Self.additionalProtectedURLs() + Self.controllers.allObjects.flatMap { $0.protectedURLs() } : []
    let blocked = clipboard.selection.sources.filter { source in
      protected.contains { Self.source(source, contains: $0) }
    }
    if !blocked.isEmpty {
      UpdateWorkAdmission.shared.endActivity(activity)
      present(Self.string("file-actions.in-use"), error: true)
      return
    }
    pendingOperationCount += 1
    Self.pendingOperationCount += 1
    if operation == .move { Self.pendingMoveCount += 1 }
    present(Self.string(operation == .move ? "file-actions.moving" : "file-actions.copying"), error: false)
    Self.queue.async {
      let report = self.executor(clipboard.selection.sources, destination, operation)
      DispatchQueue.main.async {
        self.pendingOperationCount -= 1
        Self.pendingOperationCount -= 1
        if operation == .move { Self.pendingMoveCount -= 1 }
        defer { UpdateWorkAdmission.shared.endActivity(activity) }
        let clipboardError = self.finishClipboard(clipboard, operation: operation, report: report)
        NotificationCenter.default.post(name: .mediaFilesTransferred, object: self,
          userInfo: ["report": report, "operation": operation])
        self.didTransfer(report)
        let summary = String(format: Self.string("file-actions.result"), report.successes.count, report.failures.count)
        var errors = report.failures.prefix(3).map { $0.error.localizedDescription }
        if let clipboardError { errors.append(clipboardError.localizedDescription) }
        self.present(([summary] + errors).joined(separator: "\n"),
                     error: !report.failures.isEmpty || clipboardError != nil)
      }
    }
  }

  private func finishClipboard(_ clipboard: ClipboardSnapshot, operation: MediaFileTransfer.Operation,
                               report: MediaFileTransfer.Report) -> Error? {
    guard operation == .move, !report.successes.isEmpty, let marker = clipboard.marker,
          pasteboard.changeCount == clipboard.changeCount,
          pasteboard.string(forType: Self.markerType) == marker else { return nil }
    let moved = Set(report.successes.map { $0.source.standardizedFileURL })
    let remaining = clipboard.selection.sources.filter { !moved.contains($0.url.standardizedFileURL) }
    if remaining.isEmpty {
      pasteboard.clearContents()
      Self.ownedClipboards.removeValue(forKey: pasteboard.name)
    } else {
      // Keep failed originals available for retry; successful moves must not be replayed.
      do { try writeClipboard(Selection(sources: remaining), cut: clipboard.isCut) }
      catch { return error }
    }
    return nil
  }

  private static func source(_ source: MediaFileTransfer.Source, contains protectedURL: URL) -> Bool {
    guard protectedURL.isFileURL else { return false }
    let sourcePath = source.url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    let protectedPath = protectedURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    return sourcePath == protectedPath || (source.isDirectory && protectedPath.starts(with: sourcePath))
  }

  private static func string(_ key: String) -> String {
    NSLocalizedString(key, tableName: "PlaylistBrowser", comment: "File list actions")
  }

  private static func localError(_ key: String) -> NSError {
    NSError(domain: "io.chengying.file-actions", code: 1,
            userInfo: [NSLocalizedDescriptionKey: string(key)])
  }

  private func present(_ message: String, error: Bool) {
    if let presentation { presentation(message, error); return }
    guard error else { return }
    guard let window = tableView?.window, window.isVisible, window.attachedSheet == nil else {
      NSSound.beep()
      return
    }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = Self.string("file-actions.title")
    alert.informativeText = message
    alert.addButton(withTitle: Self.string("file-actions.ok"))
    alert.beginSheetModal(for: window)
  }
}
