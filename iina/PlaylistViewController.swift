//
//  PlaylistViewController.swift
//  iina
//
//  Created by lhc on 17/8/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

fileprivate let PrefixMinLength = 7
fileprivate let FilenameMinLength = 12

fileprivate let MenuItemTagCut = 601
fileprivate let MenuItemTagCopy = 602
fileprivate let MenuItemTagPaste = 603
fileprivate let MenuItemTagDelete = 604

class PlaylistViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, SidebarViewController, NSMenuItemValidation {

  override var nibName: NSNib.Name {
    return NSNib.Name("PlaylistViewController")
  }

  weak var mainWindow: MainWindowController! {
    didSet {
      self.player = mainWindow.player
    }
  }

  weak var player: PlayerCore!

  /** Similar to the one in `QuickSettingViewController`.
   Since IBOutlet is `nil` when the view is not loaded at first time,
   use this variable to cache which tab it need to switch to when the
   view is ready. The value will be handled after loaded.
   */
  private var pendingSwitchRequest: TabViewType?

  var playlistChangeObserver: NSObjectProtocol?
  private var activationObserver: NSObjectProtocol?
  private var lifecycleObservers: [NSObjectProtocol] = []
  private var playlistReloadWork: DispatchWorkItem?
  private let sortControls = PlaylistSortControls()
  private let tagFilterControls = PlaylistTagFilterControls()
  private let filterEmptyLabel = NSTextField(wrappingLabelWithString: playlistBrowserString("filter.empty"))
  private var tagFilter: PlaylistTagFilter = .all
  private var displayedPlaylist: [MPVPlaylistItem] = []
  private var draggedPlaylistSnapshot: [MPVPlaylistItem] = []
  private var sortKey: PlaylistFileSortKey = .name
  private var sortAscending = true
  private var sortFolder: String?
  private var sortContextEntryIDs: Set<Int64> = []
  private var pendingSortIDs: [Int64]?
  private var fileMetadata: [String: PlaylistFileMetadata] = [:]
  private var metadataPaths: Set<String> = []
  private var metadataGeneration: UInt = 0
  private var metadataLoading = false
  private let metadataQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "io.github.SeanLi-Coder.ChengYingPlayer.playlist-metadata"
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .utility
    return queue
  }()

  /** Enum for tab switching */
  enum TabViewType: Int {
    case playlist = 0
    case chapters

    init?(name: String) {
      switch name {
      case "playlist":
        self = .playlist
      case "chapters":
        self = .chapters
      default:
        return nil
      }
    }
  }

  var currentTab: TabViewType = .playlist

  @IBOutlet weak var playlistTableView: NSTableView!
  @IBOutlet weak var chapterTableView: NSTableView!
  @IBOutlet weak var playlistBtn: NSButton!
  @IBOutlet weak var chaptersBtn: NSButton!
  @IBOutlet weak var tabView: NSTabView!
  @IBOutlet weak var buttonTopConstraint: NSLayoutConstraint!
  @IBOutlet weak var tabHeightConstraint: NSLayoutConstraint!
  @IBOutlet weak var deleteBtn: NSButton!
  @IBOutlet weak var loopBtn: NSButton!
  @IBOutlet weak var shuffleBtn: NSButton!
  @IBOutlet weak var sortBtn: NSButton!
  @IBOutlet weak var totalLengthLabel: NSTextField!
  @IBOutlet var subPopover: NSPopover!
  @IBOutlet var addFileMenu: NSMenu!
  @IBOutlet weak var addBtn: NSButton!
  @IBOutlet weak var removeBtn: NSButton!
  
  @Atomic private var playlistTotalLengthIsReady = false
  @Atomic private var playlistTotalLength: Double? = nil

  var downShift: CGFloat = 0 {
    didSet {
      buttonTopConstraint.constant = downShift
    }
  }

  var useCompactTabHeight = false {
    didSet {
      tabHeightConstraint.constant = useCompactTabHeight ? 32 : 48
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    withAllTableViews { (view) in
      view.dataSource = self
    }
    playlistTableView.menu?.delegate = self

    [deleteBtn, loopBtn, shuffleBtn].forEach {
      $0?.image?.isTemplate = true
      $0?.alternateImage?.isTemplate = true
    }

    if #unavailable(macOS 11.0) {
      sortBtn.image = NSImage.init(named: "triangle-down")
      sortBtn.image?.isTemplate = true
    }

    deleteBtn.toolTip = NSLocalizedString("mini_player.delete", comment: "delete")
    loopBtn.toolTip = NSLocalizedString("mini_player.loop", comment: "loop")
    shuffleBtn.toolTip = NSLocalizedString("mini_player.shuffle", comment: "shuffle")
    addBtn.toolTip = NSLocalizedString("mini_player.add", comment: "add")
    removeBtn.toolTip = NSLocalizedString("mini_player.remove", comment: "remove")
    sortBtn.toolTip = NSLocalizedString("mini_player.sort", comment: "sort")
    installSortControls()
    playlistTableView.rowHeight = 44

    hideTotalLength()

    // colors
    withAllTableViews { $0.backgroundColor = NSColor(named: .sidebarTableBackground)! }

    // handle pending switch tab request
    if pendingSwitchRequest != nil {
      switchToTab(pendingSwitchRequest!)
      pendingSwitchRequest = nil
    } else {
      // Initial display: need to draw highlight for currentTab
      updateTabButtons(activeTab: currentTab)
    }

    // notifications
    playlistChangeObserver = NotificationCenter.default.addObserver(forName: .iinaPlaylistChanged, object: player, queue: OperationQueue.main) { [weak self] _ in
      guard let self else { return }
      self.playlistTotalLengthIsReady = false
      self.playlistReloadWork?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.reloadData(playlist: true, chapters: false) }
      self.playlistReloadWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
    activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
      guard let self, self.view.window != nil, !self.view.isHiddenOrHasHiddenAncestor else { return }
      self.refreshFileMetadata(force: true)
    }
    for name in [Notification.Name.iinaPlayerStopped, .iinaPlayerShutdown] {
      lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
        self?.cancelMetadataRefresh()
      })
    }

    // register for double click action
    let action = #selector(performDoubleAction(sender:))
    playlistTableView.doubleAction = action
    playlistTableView.target = self
    chapterTableView.doubleAction = action
    chapterTableView.target = self

    // register for drag and drop
    playlistTableView.registerForDraggedTypes([.iinaPlaylistItem, .nsFilenames, .nsURL, .string])

    (subPopover.contentViewController as! SubPopoverViewController).player = player
    if let popoverView = subPopover.contentViewController?.view,
      popoverView.trackingAreas.isEmpty {
      popoverView.addTrackingArea(NSTrackingArea(rect: popoverView.bounds,
                                                 options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                                                 owner: mainWindow, userInfo: ["obj": 0]))
    }
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    reloadData(playlist: true, chapters: true)
    refreshFileMetadata(force: true)
    updateLoopBtnStatus()
  }

  deinit {
    if let playlistChangeObserver { NotificationCenter.default.removeObserver(playlistChangeObserver) }
    if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    playlistReloadWork?.cancel()
    metadataQueue.cancelAllOperations()
  }

  func reloadData(playlist: Bool, chapters: Bool) {
    guard player.info.state.active else { return }
    if playlist {
      player.getPlaylist()
      let folder = player.info.currentURL?.deletingLastPathComponent().path
      let entryIDs = Set(player.info.playlist.map(\.entryID))
      let replacedList = !entryIDs.isEmpty && entryIDs.isDisjoint(with: sortContextEntryIDs)
      if sortFolder == nil || replacedList || (folder != sortFolder && entryIDs != sortContextEntryIDs) {
        sortKey = .name
        sortAscending = true
        pendingSortIDs = nil
        tagFilter = .all
      }
      sortFolder = folder
      sortContextEntryIDs = entryIDs
      if let pendingSortIDs, player.info.playlist.map(\.entryID) != pendingSortIDs {
        self.pendingSortIDs = nil
      }
      refreshFileMetadata(force: replacedList)
      rebuildDisplayedPlaylist()
      updateSortControls()
    }
    if chapters {
      chapterTableView.reloadData()
    }
  }

  private func installSortControls() {
    guard let scrollView = playlistTableView.enclosingScrollView, let container = scrollView.superview else { return }
    // Reserve a separate toolbar without changing the existing table's bottom controls.
    let topConstraints = container.constraints.filter {
      ($0.firstItem as? NSView) === scrollView && $0.firstAttribute == .top &&
        ($0.secondItem as? NSView) === container && $0.secondAttribute == .top
    }
    NSLayoutConstraint.deactivate(topConstraints)
    sortControls.translatesAutoresizingMaskIntoConstraints = false
    tagFilterControls.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(sortControls)
    container.addSubview(tagFilterControls)
    filterEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
    filterEmptyLabel.font = .systemFont(ofSize: 12)
    filterEmptyLabel.textColor = .secondaryLabelColor
    filterEmptyLabel.alignment = .center
    filterEmptyLabel.isHidden = true
    container.addSubview(filterEmptyLabel)
    NSLayoutConstraint.activate([
      sortControls.topAnchor.constraint(equalTo: container.topAnchor),
      sortControls.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      sortControls.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      sortControls.heightAnchor.constraint(equalToConstant: 38),
      tagFilterControls.topAnchor.constraint(equalTo: sortControls.bottomAnchor),
      tagFilterControls.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      tagFilterControls.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      tagFilterControls.heightAnchor.constraint(equalToConstant: 38),
      scrollView.topAnchor.constraint(equalTo: tagFilterControls.bottomAnchor),
      filterEmptyLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 16),
      filterEmptyLabel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
      filterEmptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
    ])
    sortControls.onSortChange = { [weak self] key, ascending in self?.requestSort(key: key, ascending: ascending) }
    sortControls.onRefresh = { [weak self] in self?.refreshFileMetadata(force: true) }
    tagFilterControls.onFilterChange = { [weak self] filter in self?.requestTagFilter(filter) }
  }

  // MARK: - Visible playlist identity mapping

  /// Keep a display snapshot so a late backend mutation cannot retarget a visible row.
  private func playlistIndex(forVisibleRow row: Int, in playlist: [MPVPlaylistItem]) -> Int? {
    guard displayedPlaylist.indices.contains(row) else { return nil }
    let target = displayedPlaylist[row]
    guard target.entryID >= 0 else { return nil }
    return playlist.firstIndex { $0.entryID == target.entryID && $0.filename == target.filename }
  }

  private func playlistRows(forVisibleRows rows: IndexSet, in playlist: [MPVPlaylistItem]) -> IndexSet? {
    var result = IndexSet()
    for row in rows {
      guard let index = playlistIndex(forVisibleRow: row, in: playlist) else { return nil }
      result.insert(index)
    }
    return result
  }

  private func playlistInsertionIndex(forVisibleRow row: Int, in playlist: [MPVPlaylistItem]) -> Int? {
    guard row >= 0, row <= displayedPlaylist.count else { return nil }
    if row < displayedPlaylist.count { return playlistIndex(forVisibleRow: row, in: playlist) }
    guard !displayedPlaylist.isEmpty else { return playlist.count }
    return playlistIndex(forVisibleRow: row - 1, in: playlist).map { $0 + 1 }
  }

  // MARK: - Visible playlist presentation

  private func requestTagFilter(_ filter: PlaylistTagFilter) {
    guard let player, player.info.state.active else { return }
    tagFilter = filter
    rebuildDisplayedPlaylist()
  }

  private func rebuildDisplayedPlaylist() {
    var selectedNamesByID: [Int64: Set<String>] = [:]
    for row in playlistTableView.selectedRowIndexes where displayedPlaylist.indices.contains(row) {
      let item = displayedPlaylist[row]
      selectedNamesByID[item.entryID, default: []].insert(item.filename)
    }
    displayedPlaylist = player.info.playlist.filter { tagFilter.includes(fileMetadata[$0.filename]) }
    playlistTableView.reloadData()
    let selectedRows = IndexSet(displayedPlaylist.indices.filter { row in
      let item = displayedPlaylist[row]
      return selectedNamesByID[item.entryID]?.contains(item.filename) == true
    })
    playlistTableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
    updateTagFilterControls()
  }

  private func updateTagFilterControls() {
    tagFilterControls.update(filter: tagFilter, matchingCount: displayedPlaylist.count,
                             totalCount: player.info.playlist.count, busy: metadataLoading)
    filterEmptyLabel.isHidden = tagFilter == .all || !displayedPlaylist.isEmpty || metadataLoading
  }

  // MARK: - Playlist metadata and sorting

  private func metadataForSort(_ items: [MPVPlaylistItem]) -> [PlaylistFileMetadata] {
    items.map { item in
      fileMetadata[item.filename] ?? PlaylistFileMetadata(url: item.isNetworkResource ?
        URL(string: item.filename) ?? URL(fileURLWithPath: item.filename) : URL(fileURLWithPath: item.filename))
    }
  }

  private func updateSortControls() {
    let items = player.info.playlist
    let indices = PlaylistFileMetadata.sortedIndices(for: metadataForSort(items), by: sortKey, ascending: sortAscending)
    let manual = pendingSortIDs == nil && indices != Array(items.indices)
    sortControls.update(key: sortKey, ascending: sortAscending, manual: manual, busy: metadataLoading)
    updateTagFilterControls()
  }

  private func refreshFileMetadata(force: Bool = false) {
    guard let player, player.info.state.active else {
      cancelMetadataRefresh()
      return
    }
    let paths = Set(player.info.playlist.filter { !$0.isNetworkResource }.map(\.filename))
    guard force || paths != metadataPaths else { return }
    metadataPaths = paths
    metadataGeneration &+= 1
    let generation = metadataGeneration
    metadataQueue.cancelAllOperations()
    fileMetadata = fileMetadata.filter { paths.contains($0.key) }
    metadataLoading = !paths.isEmpty
    updateSortControls()
    guard !paths.isEmpty else {
      pendingSortIDs = nil
      rebuildDisplayedPlaylist()
      return
    }
    let operation = BlockOperation()
    operation.addExecutionBlock { [weak self, weak operation] in
      var results: [String: PlaylistFileMetadata] = [:]
      for path in paths {
        guard operation?.isCancelled == false else { return }
        results[path] = PlaylistFileMetadata.read(from: URL(fileURLWithPath: path))
      }
      guard let operation, !operation.isCancelled else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, !operation.isCancelled, self.metadataGeneration == generation else { return }
        guard let player = self.player, player.info.state.active else {
          self.cancelMetadataRefresh()
          return
        }
        self.fileMetadata = results
        self.metadataLoading = false
        if let ids = self.pendingSortIDs {
          self.pendingSortIDs = nil
          self.player.getPlaylist()
          if self.player.info.playlist.map(\.entryID) == ids {
            self.applySort()
          }
        }
        self.rebuildDisplayedPlaylist()
        self.updateSortControls()
      }
    }
    metadataQueue.addOperation(operation)
  }

  private func requestSort(key: PlaylistFileSortKey, ascending: Bool) {
    guard let player, player.info.state.active else { return }
    player.getPlaylist()
    sortKey = key
    sortAscending = ascending
    pendingSortIDs = nil
    if key == .name {
      applySort()
    } else {
      pendingSortIDs = player.info.playlist.map(\.entryID)
      refreshFileMetadata(force: true)
    }
    updateSortControls()
  }

  private func applySort() {
    guard let player, player.info.state.active else { return }
    let items = player.info.playlist
    let indices = PlaylistFileMetadata.sortedIndices(for: metadataForSort(items), by: sortKey, ascending: sortAscending)
    guard player.playlistReorder(newPlaylist: indices.map { items[$0] }) else { return }
    player.getPlaylist()
    rebuildDisplayedPlaylist()
  }

  private func cancelMetadataRefresh() {
    metadataGeneration &+= 1
    metadataQueue.cancelAllOperations()
    metadataLoading = false
    pendingSortIDs = nil
    metadataPaths.removeAll()
    fileMetadata.removeAll()
    displayedPlaylist.removeAll()
    playlistTableView.reloadData()
    filterEmptyLabel.isHidden = true
  }

  private func showTotalLength() {
    guard let playlistTotalLength = playlistTotalLength, playlistTotalLengthIsReady else { return }
    totalLengthLabel.isHidden = false
    if playlistTableView.numberOfSelectedRows > 0 {
      let info = player.info
      let rows = playlistRows(forVisibleRows: playlistTableView.selectedRowIndexes, in: info.playlist) ?? []
      let selectedDuration = info.calculateTotalDuration(rows)
      totalLengthLabel.stringValue = String(format: NSLocalizedString("playlist.total_length_with_selected", comment: "%@ of %@ selected"),
                                            VideoTime(selectedDuration).stringRepresentation,
                                            VideoTime(playlistTotalLength).stringRepresentation)
    } else {
      totalLengthLabel.stringValue = String(format: NSLocalizedString("playlist.total_length", comment: "%@ in total"),
                                            VideoTime(playlistTotalLength).stringRepresentation)
    }
  }

  private func hideTotalLength() {
    totalLengthLabel.isHidden = true
  }

  private func refreshTotalLength() {
    let totalDuration: Double? = player.info.calculateTotalDuration()
    if let duration = totalDuration {
      playlistTotalLengthIsReady = true
      playlistTotalLength = duration
      DispatchQueue.main.async {
        self.showTotalLength()
      }
    } else {
      DispatchQueue.main.async {
        self.hideTotalLength()
      }
    }
  }

  func updateLoopBtnStatus() {
    guard isViewLoaded else { return }
    let loopMode = player.getLoopMode()
    switch loopMode {
    case .off:  loopBtn.state = .off
    case .file: loopBtn.state = .on
    default:    loopBtn.state = .mixed
    }
    loopBtn.alternateImage = NSImage.init(named: loopBtn.state == .on ? "loop_file" : "loop_dark")
  }

  // MARK: - Tab switching

  /** Switch tab (call from other objects) */
  func pleaseSwitchToTab(_ tab: TabViewType) {
    if isViewLoaded {
      switchToTab(tab)
    } else {
      // cache the request
      pendingSwitchRequest = tab
    }
  }

  /** Switch tab (for internal call) */
  private func switchToTab(_ tab: TabViewType) {
    updateTabButtons(activeTab: tab)
    switch tab {
    case .playlist:
      tabView.selectTabViewItem(at: 0)
    case .chapters:
      tabView.selectTabViewItem(at: 1)
    }

    currentTab = tab
  }

  // Updates display of all tabs buttons to indicate that the given tab is active and the rest are not
  private func updateTabButtons(activeTab: TabViewType) {
    switch activeTab {
    case .playlist:
      updateTabActiveStatus(for: playlistBtn, isActive: true)
      updateTabActiveStatus(for: chaptersBtn, isActive: false)
    case .chapters:
      updateTabActiveStatus(for: playlistBtn, isActive: false)
      updateTabActiveStatus(for: chaptersBtn, isActive: true)
    }
  }

  private func updateTabActiveStatus(for btn: NSButton, isActive: Bool) {
    btn.contentTintColor = isActive ? NSColor.sidebarTabTintActive : NSColor.sidebarTabTint
  }

  // MARK: - NSTableViewDataSource

  func numberOfRows(in tableView: NSTableView) -> Int {
    if tableView == playlistTableView {
      return displayedPlaylist.count
    } else if tableView == chapterTableView {
      return player.info.chapters.count
    } else {
      return 0
    }
  }

  // MARK: - Drag and Drop

  @discardableResult
  func copyToPasteboard(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
    do {
      let selection = player.info.$playlist.withLock { playlist in
        let validRows = playlistRows(forVisibleRows: rowIndexes, in: playlist) ?? []
        return (validRows, validRows.map { playlist[$0].filename })
      }
      guard !selection.0.isEmpty else { return false }
      let indexesData = try NSKeyedArchiver.archivedData(withRootObject: selection.0, requiringSecureCoding: true)
      pboard.declareTypes([.iinaPlaylistItem, .nsFilenames], owner: tableView)
      return pboard.setData(indexesData, forType: .iinaPlaylistItem) &&
        pboard.setPropertyList(selection.1, forType: .nsFilenames)
    } catch {
      // Internal error, archivedData should not fail.
      Logger.log("Failed to copy from playlist to pasteboard: \(error)", level: .error,
                 subsystem: player.subsystem)
      return false
    }
  }

  @discardableResult
  func pasteFromPasteboard(row: Int, from pboard: NSPasteboard) -> Bool {
    let pathsToAdd: [String]
    if let paths = pboard.propertyList(forType: .nsFilenames) as? [String] {
      let playableFiles = Utility.resolveURLs(player.getPlayableFiles(in: paths.compactMap {
        $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : URL(string: $0)
      }))
      if playableFiles.count == 0 {
        return false
      }
      pathsToAdd = playableFiles.map { $0.isFileURL ? $0.path : $0.absoluteString }
    } else if let urls = pboard.propertyList(forType: .nsURL) as? [String] {
      pathsToAdd = urls
    } else if let droppedString = pboard.string(forType: .string), Regex.url.matches(droppedString) {
      pathsToAdd = [droppedString]
    } else {
      return false
    }
    player.playlistMutationLock.lock()
    defer { player.playlistMutationLock.unlock() }
    guard player.info.state.active, let playlist = player.playlistSnapshot(),
          let insertion = playlistInsertionIndex(forVisibleRow: row, in: playlist) else { return false }
    player.addToPlaylist(paths: pathsToAdd, at: insertion)
    player.postNotification(.iinaPlaylistChanged)
    return true
  }

  func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
    if tableView == playlistTableView {
      draggedPlaylistSnapshot = player.info.playlist
      return copyToPasteboard(tableView, writeRowsWith: rowIndexes, to: pboard)
    }
    return false
  }


  func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
    playlistTableView.setDropRow(row, dropOperation: .above)
    if info.draggingSource as? NSTableView === tableView {
      return tagFilter == .all ? .move : []
    }
    return player.acceptFromPasteboard(info, isPlaylist: true)
  }

  func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
    if info.draggingSource as? NSTableView === tableView {
      guard let rowData = info.draggingPasteboard.data(forType: .iinaPlaylistItem),
            let indexSet = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSIndexSet.self, from: rowData) as? IndexSet else { return false }
      // Drag & drop within playlistTableView
      // Hidden entries make a visual insertion ambiguous; clear the filter to reorder.
      player.playlistMutationLock.lock()
      defer { player.playlistMutationLock.unlock() }
      guard tagFilter == .all, player.info.state.active, let playlist = player.playlistSnapshot(),
            row >= 0, row <= playlist.count, !indexSet.isEmpty,
            indexSet.allSatisfy({ playlist.indices.contains($0) }),
            playlist.count == draggedPlaylistSnapshot.count,
            zip(playlist, draggedPlaylistSnapshot).allSatisfy({ $0.entryID == $1.entryID && $0.filename == $1.filename }),
            playlist.count == displayedPlaylist.count,
            zip(playlist, displayedPlaylist).allSatisfy({ $0.entryID == $1.entryID && $0.filename == $1.filename }) else { return false }
      var oldIndexOffset = 0, newIndexOffset = 0
      for oldIndex in indexSet {
        if oldIndex < row {
          player.playlistMove(oldIndex + oldIndexOffset, to: row)
          oldIndexOffset -= 1
        } else {
          player.playlistMove(oldIndex, to: row + newIndexOffset)
          newIndexOffset += 1
        }
        Logger.log("Playlist Drag & Drop from \(oldIndex) to \(row)", subsystem: player.subsystem)
      }
      player.postNotification(.iinaPlaylistChanged)
      return true
    }
    // Otherwise, could be copy/cut & paste within playlistTableView
    return pasteFromPasteboard(row: row, from: info.draggingPasteboard)
  }

  // MARK: - Edit Menu Support

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if currentTab == .playlist {
      switch menuItem.tag {
      case MenuItemTagCut, MenuItemTagCopy, MenuItemTagDelete:
        return playlistTableView.selectedRow != -1
      case MenuItemTagPaste:
        return NSPasteboard.general.types?.contains(.nsFilenames) ?? false
      default:
        break
      }
    }
    return menuItem.isEnabled
  }

  @objc func copy(_ sender: NSMenuItem) {
    copyToPasteboard(playlistTableView, writeRowsWith: playlistTableView.selectedRowIndexes, to: .general)
  }

  @objc func cut(_ sender: NSMenuItem) {
    if copyToPasteboard(playlistTableView, writeRowsWith: playlistTableView.selectedRowIndexes, to: .general) {
      delete(sender)
    }
  }

  @objc func paste(_ sender: NSMenuItem) {
    let dest = playlistTableView.selectedRowIndexes.first ?? 0
    pasteFromPasteboard(row: dest, from: .general)
  }


  @objc func delete(_ sender: NSMenuItem) {
    removeSelectedPlaylistItems()
  }

  private func removeSelectedPlaylistItems() {
    player.playlistMutationLock.lock()
    defer { player.playlistMutationLock.unlock() }
    guard player.info.state.active, let playlist = player.playlistSnapshot(),
          let rows = playlistRows(forVisibleRows: playlistTableView.selectedRowIndexes, in: playlist),
          !rows.isEmpty else { return }
    player.playlistRemove(rows)
  }

  // MARK: - private methods

  private func withAllTableViews(_ block: (NSTableView) -> Void) {
    block(playlistTableView)
    block(chapterTableView)
  }

  // MARK: - IBActions

  @IBAction func addToPlaylistBtnAction(_ sender: NSButton) {
    addFileMenu.popUp(positioning: nil, at: .zero, in: sender)
  }

  @IBAction func removeBtnAction(_ sender: NSButton) {
    removeSelectedPlaylistItems()
  }

  @IBAction func addFileAction(_ sender: AnyObject) {
    Utility.quickMultipleOpenPanel(title: "Add to playlist", canChooseDir: true) { urls in
      let playableFiles = self.player.getPlayableFiles(in: urls)
      if playableFiles.count != 0 {
        self.player.addToPlaylist(paths: playableFiles.map { $0.path },
                                  at: self.player.info.$playlist.withLock { $0.count })
        self.player.mainWindow.playlistView.reloadData(playlist: true, chapters: false)
        self.player.sendOSD(.addToPlaylist(playableFiles.count))
      }
    }
  }

  @IBAction func clearPlaylistBtnAction(_ sender: AnyObject) {
    player.clearPlaylist()
    player.sendOSD(.clearPlaylist)
  }

  @IBAction func playlistBtnAction(_ sender: AnyObject) {
    reloadData(playlist: true, chapters: false)
    switchToTab(.playlist)
  }

  @IBAction func chaptersBtnAction(_ sender: AnyObject) {
    reloadData(playlist: false, chapters: true)
    switchToTab(.chapters)
  }

  @IBAction func loopBtnAction(_ sender: NSButton) {
    player.nextLoopMode()
  }

  @IBAction func shuffleBtnAction(_ sender: AnyObject) {
    player.toggleShuffle()
  }


  @objc func performDoubleAction(sender: AnyObject) {
    guard let tv = sender as? NSTableView, tv.numberOfSelectedRows > 0 else { return }
    if tv == playlistTableView {
      player.playlistMutationLock.lock()
      defer { player.playlistMutationLock.unlock() }
      guard player.info.state.active, let playlist = player.playlistSnapshot(),
            let row = playlistIndex(forVisibleRow: tv.selectedRow, in: playlist) else { return }
      player.playFileInPlaylist(row)
    } else {
      let index = tv.selectedRow
      player.playChapter(index)
    }
    tv.deselectAll(self)
    tv.reloadData()
  }

  @IBAction func prefixBtnAction(_ sender: PlaylistPrefixButton) {
    sender.isFolded = !sender.isFolded
  }

  @IBAction func subBtnAction(_ sender: NSButton) {
    let row = playlistTableView.row(for: sender)
    guard let vc = subPopover.contentViewController as? SubPopoverViewController else { return }
    guard let filename = player.info.$playlist.withLock({ playlist in
      playlistIndex(forVisibleRow: row, in: playlist).map { playlist[$0].filename }
    }) else { return }
    vc.filePath = filename
    vc.tableView.reloadData()
    vc.heightConstraint.constant = (vc.tableView.rowHeight + vc.tableView.intercellSpacing.height) * CGFloat(vc.tableView.numberOfRows)
    subPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
  }

  @IBAction func sortingBtnAction(_ sender: NSButton) {
    let menu = NSMenu()
    for (index, key) in PlaylistFileSortKey.allCases.enumerated() {
      for ascending in [true, false] {
        let direction = playlistBrowserString(ascending ? "sort.ascending.short" : "sort.descending.short")
        let item = NSMenuItem(title: "\(key.title) · \(direction)", action: #selector(sortMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.tag = index * 2 + (ascending ? 0 : 1)
        item.state = sortControls.keyPopup.indexOfSelectedItem == index && sortAscending == ascending ? .on : .off
        menu.addItem(item)
      }
    }
    menu.addItem(.separator())
    let refresh = NSMenuItem(title: playlistBrowserString("refresh"), action: #selector(refreshMetadataAction), keyEquivalent: "")
    refresh.target = self
    menu.addItem(refresh)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
  }

  @objc private func sortMenuAction(_ sender: NSMenuItem) {
    let index = sender.tag / 2
    guard PlaylistFileSortKey.allCases.indices.contains(index) else { return }
    requestSort(key: PlaylistFileSortKey.allCases[index], ascending: sender.tag % 2 == 0)
  }

  @objc private func refreshMetadataAction() { refreshFileMetadata(force: true) }

  // MARK: - Table delegates

  func tableViewSelectionDidChange(_ notification: Notification) {
    let tv = notification.object as! NSTableView
    if tv == playlistTableView {
      showTotalLength()
      return
    }
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let identifier = tableColumn?.identifier else { return nil }
    let info = player.info
    let v = tableView.makeView(withIdentifier: identifier, owner: self) as! NSTableCellView

    // playlist
    if tableView == playlistTableView {
      let item: MPVPlaylistItem? = info.$playlist.withLock { playlist in
        playlistIndex(forVisibleRow: row, in: playlist).map { playlist[$0] }
      }
      guard let item else { return nil }

      if identifier == .isChosen {
        let pointer = view.userInterfaceLayoutDirection == .rightToLeft ?
            Constants.String.blackLeftPointingTriangle :  Constants.String.blackRightPointingTriangle
        v.textField?.stringValue = item.isPlaying ? pointer : ""
      } else if identifier == .trackName {
        let cellView = v as! PlaylistTrackCellView
        let configurationToken = cellView.configure(entryID: item.entryID, tags: fileMetadata[item.filename]?.tags ?? [])
        // file name
        let filename = item.filenameForDisplay
        let displayStr: String = NSString(string: filename).deletingPathExtension

        func getCachedMetadata() -> (artist: String, title: String)? {
          guard Preference.bool(for: .playlistShowMetadata) else { return nil }
          // Keep source and exported video filenames distinguishable in the editing playlist.
          let fileExtension = (item.filename as NSString).pathExtension
          guard Utility.mediaType(forExtension: fileExtension) == .audio else { return nil }
          guard let metadata = info.getCachedMetadata(item.filename) else { return nil }
          guard let artist = metadata.artist, let title = metadata.title else { return nil }
          return (artist, title)
        }

        if let prefix = player.info.currentVideosInfo.first(where: { $0.path == item.filename })?.prefix,
          !prefix.isEmpty,
          prefix.count <= displayStr.count,  // check whether prefix length > filename length
          prefix.count >= PrefixMinLength,
          filename.count > FilenameMinLength {
          cellView.setPrefix(prefix)
          cellView.setTitle(String(filename[filename.index(filename.startIndex, offsetBy: prefix.count)...]))
        } else {
          cellView.setPrefix(nil)
          cellView.setTitle(filename)
        }
        // playback progress and duration
        cellView.durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        cellView.durationLabel.stringValue = ""
        player.playlistQueue.async {
          if let (artist, title) = getCachedMetadata() {
            DispatchQueue.main.async {
              guard cellView.configurationToken == configurationToken else { return }
              cellView.setTitle(title)
              cellView.setAdditionalInfo(artist)
            }
          }
          if let cached = self.player.info.getCachedVideoDurationAndProgress(item.filename),
            let duration = cached.duration {
            // if it's cached
            if duration > 0 {
              // if FFmpeg got the duration successfully
              DispatchQueue.main.async {
                guard cellView.configurationToken == configurationToken else { return }
                cellView.durationLabel.stringValue = VideoTime(duration).stringRepresentation
                if let progress = cached.progress {
                  cellView.playbackProgressView.percentage = progress / duration
                  cellView.playbackProgressView.needsDisplay = true
                }
              }
              self.refreshTotalLength()
            }
          } else {
            // get related data and schedule a reload
            if Preference.bool(for: .prefetchPlaylistVideoDuration) {
              self.player.refreshCachedVideoInfo(forVideoPath: item.filename)
              // Only schedule a reload if data was obtained and cached to avoid looping
              if let cached = self.player.info.getCachedVideoDurationAndProgress(item.filename),
                  let duration = cached.duration, duration > 0 {
                // if FFmpeg got the duration successfully
                self.refreshTotalLength()
                DispatchQueue.main.async {
                  guard cellView.configurationToken == configurationToken,
                        let currentRow = self.displayedPlaylist.firstIndex(where: {
                          $0.entryID == item.entryID && $0.filename == item.filename
                        }) else { return }
                  self.playlistTableView.reloadData(forRowIndexes: IndexSet(integer: currentRow), columnIndexes: IndexSet(integersIn: 0...1))
                }
              }
            }
          }
        }
        // sub button
        if !info.isMatchingSubtitles,
          let matchedSubs = player.info.getMatchedSubs(item.filename), !matchedSubs.isEmpty {
          cellView.setDisplaySubButton(true)
        } else {
          cellView.setDisplaySubButton(false)
        }
        // not sure why this line exists, but let's keep it for now
        cellView.subBtn.image?.isTemplate = true
      }
      return v
    }
    // chapter
    else if tableView == chapterTableView {
      let chapters = info.chapters
      guard chapters.indices.contains(row) else {
        return nil
      }
      let chapter = chapters[row]
      // next chapter time
      let nextChapterTime = chapters[at: row+1]?.time ?? .infinite
      // construct view

      if identifier == .isChosen {
        // left column
        let pointer = view.userInterfaceLayoutDirection == .rightToLeft ?
            Constants.String.blackLeftPointingTriangle :  Constants.String.blackRightPointingTriangle
        v.textField?.stringValue = (info.chapter == row) ? pointer : ""
        return v
      } else if identifier == .trackName {
        // right column
        let cellView = v as! ChapterTableCellView
        cellView.setTitle(chapter.title.isEmpty ? "Chapter \(row)" : chapter.title)
        cellView.durationTextField.stringValue = "\(chapter.time.stringRepresentation) → \(nextChapterTime.stringRepresentation)"
        return cellView
      } else {
        return nil
      }
    }
    else {
      return nil
    }
  }

  // MARK: - Context menu

  private var contextMenuTargets: [(entryID: Int64, filename: String)] = []

  private func contextMenuSelection() -> (items: [MPVPlaylistItem], rows: IndexSet)? {
    guard let player, player.info.state.active, !contextMenuTargets.isEmpty,
          let playlist = player.playlistSnapshot() else { return nil }
    var rows = IndexSet()
    var items: [MPVPlaylistItem] = []
    for target in contextMenuTargets {
      guard let row = playlist.firstIndex(where: {
        $0.entryID == target.entryID && $0.filename == target.filename
      }) else { return nil }
      rows.insert(row)
      items.append(playlist[row])
    }
    return (items, rows)
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    let selectedRow = playlistTableView.selectedRowIndexes
    let clickedRow = playlistTableView.clickedRow
    var target = IndexSet()

    if clickedRow != -1 {
      if selectedRow.contains(clickedRow) {
        target = selectedRow
      } else {
        target.insert(clickedRow)
      }
    }

    // A menu can remain open while automatic loading or sorting changes row positions.
    // Capture identities and paths now; actions must never retarget a later occupant of a row.
    contextMenuTargets = target.compactMap { row in
      guard displayedPlaylist.indices.contains(row), displayedPlaylist[row].entryID >= 0 else { return nil }
      return (displayedPlaylist[row].entryID, displayedPlaylist[row].filename)
    }
    menu.removeAllItems()
    let items = buildMenu().items
    for item in items {
      menu.addItem(item)
    }
  }

  @IBAction func contextMenuPlayNext(_ sender: NSMenuItem) {
    player.playlistMutationLock.lock()
    defer { player.playlistMutationLock.unlock() }
    guard let selection = contextMenuSelection() else { return }
    let current = player.mpv.getInt(MPVProperty.playlistPos)
    guard current >= 0 else { return }
    var ob = 0  // index offset before current playing item
    var mc = 1  // moved item count, +1 because move to next item of current played one
    for item in selection.rows {
      if item == current { continue }
      if item < current {
        player.playlistMove(item + ob, to: current + mc + ob)
        ob -= 1
      } else {
        player.playlistMove(item, to: current + mc + ob)
      }
      mc += 1
    }
    playlistTableView.deselectAll(nil)
    player.postNotification(.iinaPlaylistChanged)
  }

  @IBAction func contextMenuPlayInNewWindow(_ sender: NSMenuItem) {
    guard let selection = contextMenuSelection() else { return }
    let files = selection.items.filter { !$0.isNetworkResource }.map { URL(fileURLWithPath: $0.filename) }
    guard !files.isEmpty else { return }
    PlayerCore.newPlayerCore.openURLs(files, shouldAutoLoad: false)
  }

  @IBAction func contextMenuRemove(_ sender: NSMenuItem) {
    player.playlistMutationLock.lock()
    defer { player.playlistMutationLock.unlock() }
    guard let selection = contextMenuSelection() else { return }
    player.playlistRemove(selection.rows)
  }

  @IBAction func contextMenuDeleteFile(_ sender: NSMenuItem) {
    guard let selection = contextMenuSelection() else { return }
    Logger.log("User chose to delete \(selection.items.count) playlist files", subsystem: player.subsystem)

    var trashedPaths = Set<String>()
    for playlistItem in selection.items {
      guard !playlistItem.isNetworkResource else { continue }
      guard !trashedPaths.contains(playlistItem.filename) else { continue }
      let url = URL(fileURLWithPath: playlistItem.filename)
      do {
        Logger.log("Trashing entry \(playlistItem.entryID): \(url.standardizedFileURL)", subsystem: player.subsystem)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        trashedPaths.insert(playlistItem.filename)
      } catch let error {
        Utility.showAlert("playlist.error_deleting", arguments: [error.localizedDescription])
      }
    }
    // File errors may display a modal alert and allow another playlist change.
    // Resolve the successful entries again instead of removing stale numeric rows.
    guard let player, player.info.state.active, !trashedPaths.isEmpty else { return }
    player.playlistMutationLock.lock()
    defer { player.playlistMutationLock.unlock() }
    guard let playlist = player.playlistSnapshot() else { return }
    let selectedIDs = Set(selection.items.map(\.entryID))
    let successes = IndexSet(playlist.indices.filter {
      selectedIDs.contains(playlist[$0].entryID) && trashedPaths.contains(playlist[$0].filename)
    })
    player.playlistRemove(successes)
  }

  @IBAction func contextMenuDeleteFileAfterPlayback(_ sender: NSMenuItem) {
    // WIP
  }

  @IBAction func contextMenuShowInFinder(_ sender: NSMenuItem) {
    guard let selection = contextMenuSelection() else { return }
    let urls = selection.items.filter { !$0.isNetworkResource }.map { URL(fileURLWithPath: $0.filename) }
    playlistTableView.deselectAll(nil)
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  @IBAction func contextMenuAddSubtitle(_ sender: NSMenuItem) {
    guard let selection = contextMenuSelection(), let item = selection.items.first else { return }
    let filename = item.filename
    let fileURL = URL(fileURLWithPath: filename).deletingLastPathComponent()
    Utility.quickMultipleOpenPanel(title: NSLocalizedString("alert.choose_media_file.title", comment: "Choose Media File"), dir: fileURL, canChooseDir: true) { subURLs in
      guard let player = self.player, player.info.state.active,
            player.playlistSnapshot()?.contains(where: { $0.entryID == item.entryID && $0.filename == filename }) == true else { return }
      for subURL in subURLs {
        guard subURL.isFileURL, Utility.supportedFileExt[.sub]!.contains(subURL.pathExtension.lowercased()) else { continue }
        player.info.$matchedSubs.withLock {
          if !$0[filename, default: []].contains(subURL) { $0[filename, default: []].append(subURL) }
        }
      }
      self.playlistTableView.reloadData()
    }
  }

  @IBAction func contextMenuWrongSubtitle(_ sender: NSMenuItem) {
    guard let selection = contextMenuSelection() else { return }
    for item in selection.items {
      player.info.$matchedSubs.withLock { $0[item.filename]?.removeAll() }
    }
    playlistTableView.reloadData()
  }

  @IBAction func contextOpenInBrowser(_ sender: NSMenuItem) {
    guard let selection = contextMenuSelection() else { return }
    selection.items.forEach { info in
      if info.isNetworkResource, let url = URL(string: info.filename) {
        NSWorkspace.shared.open(url)
      }
    }
  }

  @IBAction func contextCopyURL(_ sender: NSMenuItem) {
    guard let selection = contextMenuSelection() else { return }
    let urls = selection.items.compactMap { info -> String? in
      return info.isNetworkResource ? info.filename : nil
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([urls.joined(separator: "\n") as NSString])
  }

  private func buildMenu() -> NSMenu {
    let result = NSMenu()
    let selection = contextMenuSelection()
    let rows = selection?.rows ?? []
    let items = selection?.items ?? []
    let isSingleItem = rows.count == 1

    if let firstURL = items.first {
      let matchedSubCount = player.info.getMatchedSubs(firstURL.filename)?.count ?? 0
      let title: String = isSingleItem ?
        firstURL.filenameForDisplay :
        String(format: NSLocalizedString("pl_menu.title_multi", comment: "%d Items"), rows.count)

      result.addItem(withTitle: title)
      result.addItem(NSMenuItem.separator())
      result.addItem(withTitle: NSLocalizedString("pl_menu.play_next", comment: "Play Next"), action: #selector(self.contextMenuPlayNext(_:)))
      result.addItem(withTitle: NSLocalizedString("pl_menu.play_in_new_window", comment: "Play in New Window"), action: #selector(self.contextMenuPlayInNewWindow(_:)))
      result.addItem(withTitle: NSLocalizedString(isSingleItem ? "pl_menu.remove" : "pl_menu.remove_multi", comment: "Remove"), action: #selector(self.contextMenuRemove(_:)))

      if !player.isInMiniPlayer {
        result.addItem(NSMenuItem.separator())
        if isSingleItem {
          result.addItem(withTitle: String(format: NSLocalizedString("pl_menu.matched_sub", comment: "Matched %d Subtitle(s)"), matchedSubCount))
          result.addItem(withTitle: NSLocalizedString("pl_menu.add_sub", comment: "Add Subtitle…"), action: #selector(self.contextMenuAddSubtitle(_:)))
        }
        if matchedSubCount != 0 {
          result.addItem(withTitle: NSLocalizedString("pl_menu.wrong_sub", comment: "Wrong Subtitle"), action: #selector(self.contextMenuWrongSubtitle(_:)))
        }
      }

      result.addItem(NSMenuItem.separator())
      // network resources related operations
      let networkCount = items.filter(\.isNetworkResource).count
      if networkCount != 0 {
        result.addItem(withTitle: NSLocalizedString("pl_menu.browser", comment: "Open in Browser"), action: #selector(self.contextOpenInBrowser(_:)))
        result.addItem(withTitle: NSLocalizedString(networkCount == 1 ? "pl_menu.copy_url" : "pl_menu.copy_url_multi", comment: "Copy URL(s)"), action: #selector(self.contextCopyURL(_:)))
        result.addItem(NSMenuItem.separator())
      }
      // file related operations
      let localCount = rows.count - networkCount
      if localCount != 0 {
        result.addItem(withTitle: NSLocalizedString(localCount == 1 ? "pl_menu.delete" : "pl_menu.delete_multi", comment: "Delete"), action: #selector(self.contextMenuDeleteFile(_:)))
        // result.addItem(withTitle: NSLocalizedString(isSingleItem ? "pl_menu.delete_after_play" : "pl_menu.delete_after_play_multi", comment: "Delete After Playback"), action: #selector(self.contextMenuDeleteFileAfterPlayback(_:)))

        result.addItem(withTitle: NSLocalizedString("pl_menu.show_in_finder", comment: "Show in Finder"), action: #selector(self.contextMenuShowInFinder(_:)))
        result.addItem(NSMenuItem.separator())
      }
    }

    // menu items from plugins
    var hasPluginMenuItems = false
    let filenames = Array(rows)
    let pluginMenuItems = player.plugins.map {
      plugin -> (JavascriptPluginInstance, [JavascriptPluginMenuItem]) in
      if let builder = (plugin.apis["playlist"] as! JavascriptAPIPlaylist).menuItemBuilder?.value,
        let value = builder.call(withArguments: [filenames]),
        value.isObject,
        let items = value.toObject() as? [JavascriptPluginMenuItem] {
        hasPluginMenuItems = true
        return (plugin, items)
      }
      return (plugin, [])
    }
    if hasPluginMenuItems {
      result.addItem(withTitle: NSLocalizedString("preference.plugins", comment: "Plugins"))
      for (plugin, items) in pluginMenuItems {
        for item in items {
          add(menuItemDef: item, to: result, for: plugin)
        }
      }
      result.addItem(NSMenuItem.separator())
    }

    result.addItem(withTitle: NSLocalizedString("pl_menu.add_file", comment: "Add File"), action: #selector(self.addFileAction(_:)))
    result.addItem(withTitle: NSLocalizedString("pl_menu.clear_playlist", comment: "Clear Playlist"), action: #selector(self.clearPlaylistBtnAction(_:)))
    return result
  }

  @discardableResult
  private func add(menuItemDef item: JavascriptPluginMenuItem,
                   to menu: NSMenu,
                   for plugin: JavascriptPluginInstance) -> NSMenuItem {
    if (item.isSeparator) {
      let item = NSMenuItem.separator()
      menu.addItem(item)
      return item
    }

    let menuItem: NSMenuItem
    if item.action == nil {
      menuItem = menu.addItem(withTitle: item.title, action: nil, target: plugin, obj: item)
    } else {
      menuItem = menu.addItem(withTitle: item.title,
                              action: #selector(plugin.playlistMenuItemAction(_:)),
                              target: plugin,
                              obj: item)
    }

    menuItem.isEnabled = item.enabled
    menuItem.state = item.selected ? .on : .off
    if !item.items.isEmpty {
      menuItem.submenu = NSMenu()
      for submenuItem in item.items {
        add(menuItemDef: submenuItem, to: menuItem.submenu!, for: plugin)
      }
    }
    return menuItem
  }
}


class PlaylistTrackCellView: NSTableCellView {
  @IBOutlet weak var subBtn: NSButton!
  @IBOutlet weak var subBtnWidthConstraint: NSLayoutConstraint!
  @IBOutlet weak var subBtnTrailingConstraint: NSLayoutConstraint!
  @IBOutlet weak var prefixBtn: PlaylistPrefixButton!
  @IBOutlet weak var infoLabel: NSTextField!
  @IBOutlet weak var infoLabelTrailingConstraint: NSLayoutConstraint!
  @IBOutlet weak var durationLabel: NSTextField!
  @IBOutlet weak var playbackProgressView: PlaylistPlaybackProgressView!
  private let tagList = PlaylistTagListView()
  private(set) var representedEntryID: Int64?
  private(set) var configurationToken = UUID()

  override func awakeFromNib() {
    super.awakeFromNib()
    guard let title = textField else { return }
    let topRow: [NSView] = [title, prefixBtn, infoLabel, durationLabel, subBtn]
    NSLayoutConstraint.deactivate(constraints.filter { constraint in
      constraint.firstAttribute == .centerY && constraint.secondAttribute == .centerY &&
        (constraint.secondItem as? NSView) === self && topRow.contains { $0 === (constraint.firstItem as? NSView) }
    })
    tagList.translatesAutoresizingMaskIntoConstraints = false
    addSubview(tagList)
    NSLayoutConstraint.activate([
      title.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      prefixBtn.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      infoLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      durationLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      subBtn.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      tagList.leadingAnchor.constraint(equalTo: leadingAnchor),
      tagList.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      tagList.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
      tagList.heightAnchor.constraint(equalToConstant: 14)
    ])
  }

  @discardableResult
  func configure(entryID: Int64, tags: [PlaylistFileTag]) -> UUID {
    configurationToken = UUID()
    representedEntryID = entryID
    playbackProgressView.percentage = 0
    playbackProgressView.needsDisplay = true
    durationLabel.stringValue = ""
    setAdditionalInfo(nil)
    tagList.setTags(tags)
    return configurationToken
  }

  func setPrefix(_ prefix: String?) {
    if let prefix = prefix {
      prefixBtn.hasPrefix = true
      prefixBtn.text = prefix
    } else {
      prefixBtn.hasPrefix = false
    }
  }

  func setDisplaySubButton(_ show: Bool) {
    if show {
      subBtn.isHidden = false
      subBtnWidthConstraint.constant = 12
      subBtnTrailingConstraint.constant = 4
    } else {
      subBtn.isHidden = true
      subBtnWidthConstraint.constant = 0
      subBtnTrailingConstraint.constant = 0
    }
  }

  func setAdditionalInfo(_ string: String?) {
    if let string = string {
      infoLabel.isHidden = false
      infoLabelTrailingConstraint.constant = 4
      infoLabel.stringValue = string
      infoLabel.toolTip = string
    } else {
      infoLabel.isHidden = true
      infoLabelTrailingConstraint.constant = 0
      infoLabel.stringValue = ""
    }
  }

  func setTitle(_ title: String) {
    textField?.stringValue = title
    textField?.toolTip = title
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    representedEntryID = nil
    configurationToken = UUID()
    tagList.setTags([])
    playbackProgressView.percentage = 0
    playbackProgressView.needsDisplay = true
    setPrefix(nil)
    setAdditionalInfo(nil)
  }
}


class PlaylistPrefixButton: NSButton {

  var text = "" {
    didSet {
      refresh()
    }
  }

  var hasPrefix = true {
    didSet {
      refresh()
    }
  }

  var isFolded = true {
    didSet {
      refresh()
    }
  }

  private func refresh() {
    self.title = hasPrefix ? (isFolded ? "…" : text) : ""
  }

}

class SubPopoverViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource {

  @IBOutlet weak var tableView: NSTableView!
  @IBOutlet weak var playlistTableView: NSTableView!
  @IBOutlet weak var heightConstraint: NSLayoutConstraint!

  weak var player: PlayerCore!

  var filePath: String = ""

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    return false
  }

  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
    guard let matchedSubs = player.info.getMatchedSubs(filePath), matchedSubs.indices.contains(row) else { return nil }
    return matchedSubs[row].lastPathComponent
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    return player.info.getMatchedSubs(filePath)?.count ?? 0
  }

  @IBAction func wrongSubBtnAction(_ sender: AnyObject) {
    player.info.$matchedSubs.withLock { $0[filePath]?.removeAll() }
    tableView.reloadData()
    // Every visible occurrence may use this file, and backend rows can be filtered out.
    playlistTableView.reloadData()
  }
}

class ChapterTableCellView: NSTableCellView {
  @IBOutlet weak var durationTextField: NSTextField!

  func setTitle(_ title: String) {
    textField?.stringValue = title
    textField?.toolTip = title
  }
}
