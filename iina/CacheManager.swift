//
//  CacheManager.swift
//  iina
//
//  Created by lhc on 28/9/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

class CacheManager {

  static var shared = CacheManager()

  private var isJobRunning = false
  private let lock = NSRecursiveLock()
  private var refreshPending = true

  var needsRefresh: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return refreshPending
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      refreshPending = newValue
    }
  }

  private var cachedContents: [URL]?

  private func cacheFolderContents() -> [URL]? {
    if refreshPending {
      cachedContents = try? FileManager.default.contentsOfDirectory(at: Utility.thumbnailCacheURL,
                                                                    includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey],
                                                                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
      if cachedContents != nil { refreshPending = false }
    }
    return cachedContents
  }

  func getCacheSize() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return cacheFolderContents()?.reduce(0 as Int) { totalSize, url in
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
      let (total, overflow) = totalSize.addingReportingOverflow(max(0, size))
      return overflow ? Int.max : total
    } ?? 0
  }

  func clearOldCache(excluding preservedURL: URL? = nil) {
    lock.lock()
    defer { lock.unlock() }
    guard !isJobRunning else { return }
    isJobRunning = true
    defer {
      isJobRunning = false
      refreshPending = true
    }

    let maxCacheSize = Preference.integer(for: .maxThumbnailPreviewCacheSize)
    // if full, delete 50% of max cache
    let (cacheBytes, overflow) = maxCacheSize.multipliedReportingOverflow(by: FloatingPointByteCountFormatter.PrefixFactor.mi.rawValue)
    guard maxCacheSize > 0, !overflow else { return }
    let cacheToDelete = cacheBytes / 2

    // sort by access date
    guard let contents = cacheFolderContents()?.sorted(by: { url1, url2 in
      let date1 = (try? url1.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? Date.distantPast
      let date2 = (try? url2.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? Date.distantPast
      return date1.compare(date2) == .orderedAscending
    }) else { return }

    // delete old cache
    var clearedCacheSize = 0
    for url in contents {
      if url == preservedURL { continue }
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
      if clearedCacheSize < cacheToDelete {
        // Only remove regular cache files. A directory or symlink is not a cache entry.
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
        if (try? FileManager.default.removeItem(at: url)) != nil {
          let (total, overflow) = clearedCacheSize.addingReportingOverflow(max(0, size))
          clearedCacheSize = overflow ? Int.max : total
        }
      } else {
        break
      }
    }
  }

}
