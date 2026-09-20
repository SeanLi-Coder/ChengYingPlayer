import Cocoa

/// A shallow directory browser shared by video and image windows.
/// Every entry describes one direct child; browsing never recursively scans descendants.
final class MediaFolderBrowserView: NSView, NSTableViewDataSource, NSTableViewDelegate {
  struct Entry: Equatable {
    let metadata: PlaylistFileMetadata
    let isDirectory: Bool
    var url: URL { metadata.url }
  }

  var onOpenFile: ((URL) -> Void)?
  /// Called on the main thread after a successful load, and after filter/sort changes.
  /// Contains only visible regular media files in the current display order, without
  /// directories. Loading, cancellation and errors do not publish an empty snapshot.
  var onDirectoryLoaded: ((URL, [PlaylistFileMetadata]) -> Void)?
  /// Hosts can defer activation while an edit or application update is protected.
  /// `force` refreshes a snapshot but never bypasses this admission check.
  var canNavigate: (() -> Bool)?

  private(set) var directoryURL: URL?
  private(set) var visibleEntries: [Entry] = []
  /// All accepted media files in the current sort order, before the visual tag filter.
  /// Image hosts can use this snapshot to preserve their slideshow while filtering.
  private(set) var mediaFiles: [PlaylistFileMetadata] = []
  private(set) var isLoading = false
  private(set) var loadError: Error?
  private(set) var sortKey: PlaylistFileSortKey = .name
  private(set) var sortAscending = true
  private(set) var tagFilter: PlaylistTagFilter = .all

  let tableView = NSTableView()
  let parentButton = NSButton()
  let folderLabel = NSTextField(labelWithString: "")
  let statusLabel = NSTextField(wrappingLabelWithString: "")
  let sortControls = PlaylistSortControls()
  let tagFilterControls = PlaylistTagFilterControls()

  private let supportedExtensions: Set<String>
  private let scrollView = NSScrollView()
  private var entries: [Entry] = []
  private var selectedURL: URL?
  private var hasLoadedDirectory = false
  private var loadGeneration: UInt64 = 0
  private var pendingLoad: MediaFolderLoadCancellation?
  private var restoringSelection = false
  private static let loadQueue = DispatchQueue(label: "io.chengying.media-folder-browser",
                                               qos: .userInitiated, attributes: .concurrent)

  init(extensions: Set<String>) {
    supportedExtensions = Set(extensions.map { $0.lowercased() })
    super.init(frame: .zero)
    configureView()
    updateControls()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit { pendingLoad?.cancel() }

  func showDirectory(_ url: URL, selectedURL: URL? = nil, force: Bool = false) {
    guard canNavigate?() ?? true else { return }
    let directory = url.standardizedFileURL
    if directoryURL == directory, !force, isLoading || hasLoadedDirectory {
      if let selectedURL { selectFile(selectedURL) }
      return
    }

    pendingLoad?.cancel()
    loadGeneration &+= 1
    let generation = loadGeneration
    let cancellation = MediaFolderLoadCancellation()
    pendingLoad = cancellation
    directoryURL = directory
    self.selectedURL = selectedURL?.standardizedFileURL
    entries = []
    visibleEntries = []
    mediaFiles = []
    hasLoadedDirectory = false
    isLoading = true
    loadError = nil
    tableView.reloadData()
    tableView.deselectAll(nil)
    updateControls()

    let extensions = supportedExtensions
    Self.loadQueue.async { [weak self] in
      let result: Result<[Entry], Error>
      do {
        result = .success(try Self.readDirectory(directory, extensions: extensions, cancellation: cancellation))
      } catch {
        result = .failure(error)
      }
      guard !cancellation.isCancelled else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.loadGeneration == generation, !cancellation.isCancelled else { return }
        self.pendingLoad = nil
        self.isLoading = false
        switch result {
        case .success(let entries):
          self.entries = entries
          self.hasLoadedDirectory = true
          self.applyPresentation()
        case .failure(let error):
          self.loadError = error
          self.updateControls()
        }
      }
    }
  }

  func selectFile(_ url: URL?) {
    selectedURL = url?.standardizedFileURL
    restoreSelection()
  }

  func refresh() {
    guard let directoryURL else { return }
    showDirectory(directoryURL, selectedURL: selectedURL, force: true)
  }

  /// Invalidate results immediately; the next showDirectory call can retry the load.
  func cancelPendingLoads() {
    pendingLoad?.cancel()
    pendingLoad = nil
    loadGeneration &+= 1
    isLoading = false
    updateControls()
  }

  private static func readDirectory(_ directory: URL, extensions: Set<String>,
                                    cancellation: MediaFolderLoadCancellation) throws -> [Entry] {
    guard directory.isFileURL, !directory.path.contains("\0"),
          directory.host == nil || directory.host == "" || directory.host?.lowercased() == "localhost" else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey,
                                     .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey]
    // This API only enumerates direct children, including when the user explicitly
    // navigates into a directory reached through a symbolic-link path.
    let children = try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants])
    var result: [Entry] = []
    for child in children {
      guard !cancellation.isCancelled else { return [] }
      guard let values = try? child.resourceValues(forKeys: keys),
            values.isHidden != true, values.isPackage != true,
            values.isSymbolicLink != true, values.isAliasFile != true else { continue }
      let isDirectory = values.isDirectory == true
      guard isDirectory || (values.isRegularFile == true && extensions.contains(child.pathExtension.lowercased())) else {
        continue
      }
      let metadata = PlaylistFileMetadata.read(from: child.standardizedFileURL)
      guard !cancellation.isCancelled else { return [] }
      result.append(Entry(metadata: metadata, isDirectory: isDirectory))
    }
    return result
  }

  private func configureView() {
    identifier = NSUserInterfaceItemIdentifier("media.folder-browser")
    parentButton.bezelStyle = .texturedRounded
    parentButton.imagePosition = .imageOnly
    parentButton.image = ChengYingStyle.symbol("arrow.up")
    parentButton.contentTintColor = ChengYingStyle.accent
    parentButton.target = self
    parentButton.action = #selector(goToParent)
    parentButton.toolTip = playlistBrowserString("folder.parent")
    parentButton.setAccessibilityLabel(playlistBrowserString("folder.parent"))
    folderLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    folderLabel.lineBreakMode = .byTruncatingMiddle
    folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    folderLabel.setAccessibilityLabel(playlistBrowserString("folder.current"))
    let header = NSStackView(views: [parentButton, folderLabel])
    header.orientation = .horizontal
    header.spacing = 8
    header.alignment = .centerY

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("media.folder-browser.name"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.rowHeight = 58
    tableView.intercellSpacing = NSSize(width: 0, height: 2)
    tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    tableView.allowsMultipleSelection = false
    tableView.allowsEmptySelection = true
    tableView.backgroundColor = .clear
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.doubleAction = #selector(openSelectedEntry)
    tableView.setAccessibilityLabel(playlistBrowserString("folder.contents"))
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder

    statusLabel.font = .systemFont(ofSize: 12)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.alignment = .center
    statusLabel.maximumNumberOfLines = 0
    for view in [header, sortControls, tagFilterControls, scrollView, statusLabel] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      header.topAnchor.constraint(equalTo: topAnchor, constant: 5),
      header.heightAnchor.constraint(equalToConstant: 30),
      parentButton.widthAnchor.constraint(equalToConstant: 28),
      parentButton.heightAnchor.constraint(equalToConstant: 26),
      sortControls.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
      sortControls.leadingAnchor.constraint(equalTo: leadingAnchor),
      sortControls.trailingAnchor.constraint(equalTo: trailingAnchor),
      sortControls.heightAnchor.constraint(equalToConstant: 34),
      tagFilterControls.topAnchor.constraint(equalTo: sortControls.bottomAnchor),
      tagFilterControls.leadingAnchor.constraint(equalTo: leadingAnchor),
      tagFilterControls.trailingAnchor.constraint(equalTo: trailingAnchor),
      tagFilterControls.heightAnchor.constraint(equalToConstant: 36),
      scrollView.topAnchor.constraint(equalTo: tagFilterControls.bottomAnchor, constant: 2),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      statusLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 16),
      statusLabel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
      statusLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
    ])
    sortControls.onSortChange = { [weak self] key, ascending in
      guard let self else { return }
      self.sortKey = key
      self.sortAscending = ascending
      self.applyPresentation()
    }
    sortControls.onRefresh = { [weak self] in self?.refresh() }
    tagFilterControls.onFilterChange = { [weak self] filter in
      guard let self else { return }
      self.tagFilter = filter
      self.applyPresentation()
    }
  }

  private func applyPresentation() {
    let directories = entries.filter(\.isDirectory)
    let files = entries.filter { !$0.isDirectory }
    func sorted(_ entries: [Entry]) -> [Entry] {
      PlaylistFileMetadata.sortedIndices(for: entries.map(\.metadata), by: sortKey,
                                         ascending: sortAscending).map { entries[$0] }
    }
    let sortedFiles = sorted(files)
    mediaFiles = sortedFiles.map(\.metadata)
    // Folders remain reachable even if their own tags do not match the filter.
    visibleEntries = sorted(directories) + sortedFiles.filter { tagFilter.includes($0.metadata) }
    restoringSelection = true
    tableView.reloadData()
    restoringSelection = false
    restoreSelection()
    updateControls()
    if hasLoadedDirectory, let directoryURL {
      onDirectoryLoaded?(directoryURL, visibleEntries.filter { !$0.isDirectory }.map(\.metadata))
    }
  }

  private func restoreSelection() {
    restoringSelection = true
    defer { restoringSelection = false }
    if let selectedURL, let row = visibleEntries.firstIndex(where: { $0.url.standardizedFileURL == selectedURL }) {
      tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      tableView.scrollRowToVisible(row)
    } else {
      tableView.deselectAll(nil)
    }
  }

  private func updateControls() {
    folderLabel.stringValue = directoryURL.map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent }
      ?? playlistBrowserString("folder.title")
    folderLabel.toolTip = directoryURL?.path
    folderLabel.setAccessibilityValue(directoryURL?.path ?? "")
    parentButton.isEnabled = directoryURL.map { $0.path != $0.deletingLastPathComponent().path } ?? false
    sortControls.update(key: sortKey, ascending: sortAscending, manual: false, busy: isLoading)
    sortControls.refreshButton.isEnabled = directoryURL != nil && !isLoading
    let files = entries.filter { !$0.isDirectory }
    let visibleFiles = visibleEntries.filter { !$0.isDirectory }
    tagFilterControls.update(filter: tagFilter, matchingCount: visibleFiles.count, totalCount: files.count,
                             busy: isLoading)
    let filterHelp = playlistBrowserString("folder.filter.scope")
    tagFilterControls.toolTip = filterHelp
    tagFilterControls.filterPopup.toolTip = tagFilter.title + "\n" + filterHelp
    tagFilterControls.filterPopup.setAccessibilityHelp(filterHelp)
    for view in tagFilterControls.subviews where view.identifier?.rawValue == "playlist.tag-filter.count" {
      view.toolTip = filterHelp
    }

    if isLoading {
      statusLabel.stringValue = playlistBrowserString("folder.loading")
    } else if let loadError {
      statusLabel.stringValue = String(format: playlistBrowserString("folder.error"), loadError.localizedDescription)
    } else if directoryURL == nil {
      statusLabel.stringValue = playlistBrowserString("folder.no-directory")
    } else if !hasLoadedDirectory {
      statusLabel.stringValue = playlistBrowserString("folder.cancelled")
    } else if visibleEntries.isEmpty {
      statusLabel.stringValue = playlistBrowserString(tagFilter == .all ? "folder.empty" : "filter.empty")
    } else {
      statusLabel.stringValue = ""
    }
    statusLabel.isHidden = statusLabel.stringValue.isEmpty
    statusLabel.toolTip = statusLabel.stringValue
  }

  @objc func goToParent() {
    guard let directoryURL else { return }
    let parent = directoryURL.deletingLastPathComponent()
    guard parent.path != directoryURL.path else { return }
    showDirectory(parent, selectedURL: directoryURL)
  }

  @objc func openSelectedEntry() {
    guard canNavigate?() ?? true, !isLoading else { return }
    let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
    guard visibleEntries.indices.contains(row) else { return }
    let entry = visibleEntries[row]
    if entry.isDirectory {
      showDirectory(entry.url)
    } else {
      onOpenFile?(entry.url)
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { visibleEntries.count }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !restoringSelection, visibleEntries.indices.contains(tableView.selectedRow) else { return }
    selectedURL = visibleEntries[tableView.selectedRow].url.standardizedFileURL
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard visibleEntries.indices.contains(row) else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("media.folder-browser.cell")
    let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? MediaFolderBrowserCell
      ?? MediaFolderBrowserCell()
    cell.identifier = identifier
    cell.configure(visibleEntries[row], sortKey: sortKey)
    return cell
  }
}

private final class MediaFolderLoadCancellation {
  private let lock = NSLock()
  private var cancelled = false
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

private final class MediaFolderBrowserCell: NSTableCellView {
  private let icon = NSImageView()
  private let nameLabel = NSTextField(labelWithString: "")
  private let detailLabel = NSTextField(labelWithString: "")
  private let tagsView = PlaylistTagListView()
  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter
  }()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    textField = nameLabel
    nameLabel.font = .systemFont(ofSize: 12)
    nameLabel.lineBreakMode = .byTruncatingMiddle
    detailLabel.font = .systemFont(ofSize: 10)
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.lineBreakMode = .byTruncatingTail
    icon.imageScaling = .scaleProportionallyDown
    for view in [icon, nameLabel, detailLabel, tagsView] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      icon.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      icon.widthAnchor.constraint(equalToConstant: 18),
      icon.heightAnchor.constraint(equalToConstant: 18),
      nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
      nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
      nameLabel.heightAnchor.constraint(equalToConstant: 17),
      detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
      detailLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
      detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
      detailLabel.heightAnchor.constraint(equalToConstant: 14),
      tagsView.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
      tagsView.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
      tagsView.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 1),
      tagsView.heightAnchor.constraint(equalToConstant: 15),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(_ entry: MediaFolderBrowserView.Entry, sortKey: PlaylistFileSortKey) {
    nameLabel.stringValue = entry.metadata.name
    icon.image = ChengYingStyle.symbol(entry.isDirectory ? "folder.fill" : "doc")
    icon.contentTintColor = entry.isDirectory ? ChengYingStyle.accent : .secondaryLabelColor
    var details: [String] = []
    if entry.isDirectory {
      details.append(playlistBrowserString("folder.kind"))
    } else if let size = entry.metadata.fileSize {
      details.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
    }
    let date = sortKey == .created ? entry.metadata.creationDate : entry.metadata.modificationDate
    if let date {
      let dateTitle = playlistBrowserString(sortKey == .created ? "sort.created" : "sort.modified")
      details.append(dateTitle + ": " + Self.dateFormatter.string(from: date))
    }
    detailLabel.stringValue = details.joined(separator: " · ")
    tagsView.setTags(entry.metadata.tags)
    let tagNames = entry.metadata.tags.map(\.name).joined(separator: ", ")
    toolTip = [entry.url.path, detailLabel.stringValue, tagNames].filter { !$0.isEmpty }.joined(separator: "\n")
    detailLabel.toolTip = detailLabel.stringValue
    setAccessibilityLabel([entry.metadata.name, detailLabel.stringValue, tagNames]
      .filter { !$0.isEmpty }.joined(separator: ", "))
  }
}
