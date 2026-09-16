//
//  MPVCommandWrappers.swift
//  iina
//
//  Created by Yuze Jiang on 2025/05/25.
//  Copyright © 2025 lhc. All rights reserved.
//

extension MPVController {
  func playlistInsert(_ path: String, index: Int) {
    guard Utility.isLocalMediaPath(path) else { return }
    command(.loadfile, args: [path, "insert-at", index.description], level: .verbose)
  }

  func playlistAppend(_ path: String) {
    guard Utility.isLocalMediaPath(path) else { return }
    command(.loadfile, args: [path, "append"], level: .verbose)
  }

  func playlistMove(_ from: Int, to: Int) {
    command(.playlistMove, args: ["\(from)", "\(to)"], level: .verbose)
  }

  func playlistRemove(_ index: Int) {
    command(.playlistRemove, args: [index.description], level: .verbose)
  }

}
