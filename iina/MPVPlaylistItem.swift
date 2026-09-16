//
//  MPVPlaylistItem.swift
//  iina
//
//  Created by lhc on 23/8/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

class MPVPlaylistItem: NSObject, Identifiable {

  /// mpv keeps this identity stable across reorders, including duplicate filenames.
  let entryID: Int64
  let snapshotEntryIDs: [Int64]

  var id: AnyHashable {
    return entryID >= 0 ? AnyHashable(entryID) : AnyHashable(ObjectIdentifier(self))
  }

  /** Actually this is the path. Use `filename` to conform mpv API's naming. */
  var filename: String

  /** Title or the real filename */
  var filenameForDisplay: String {
    return title ?? (isNetworkResource ? filename : NSString(string: filename).lastPathComponent)
  }

  var isCurrent: Bool
  var isPlaying: Bool
  var isNetworkResource: Bool

  var title: String?

  init(filename: String, isCurrent: Bool, isPlaying: Bool, title: String?,
       entryID: Int64 = -1, snapshotEntryIDs: [Int64] = []) {
    self.entryID = entryID
    self.snapshotEntryIDs = snapshotEntryIDs
    self.filename = filename
    self.isCurrent = isCurrent
    self.isPlaying = isPlaying
    self.title = title
    self.isNetworkResource = Regex.url.matches(filename)
  }

  /// Parse a single native-property snapshot instead of racing separate index-based reads.
  static func playlist(from node: Any?) -> [MPVPlaylistItem]? {
    guard let entries = node as? [[String: Any?]] else { return nil }
    let ids = entries.compactMap { $0["id"] as? Int64 }
    guard ids.count == entries.count, ids.allSatisfy({ $0 >= 0 }),
          Set(ids).count == ids.count else { return nil }
    var result: [MPVPlaylistItem] = []
    for (index, entry) in entries.enumerated() {
      guard let filename = entry["filename"] as? String else { return nil }
      result.append(MPVPlaylistItem(filename: filename,
                                    isCurrent: entry["current"] as? Bool ?? false,
                                    isPlaying: entry["playing"] as? Bool ?? false,
                                    title: entry["title"] as? String,
                                    entryID: ids[index], snapshotEntryIDs: ids))
    }
    return result
  }
}
