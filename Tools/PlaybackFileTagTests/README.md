# Playback Finder tag storage checks

This CLI suite compiles the production `PlaybackFileTags` service and the existing
`PlaylistFileMetadata` reader. It creates only synthetic regular files in a unique
repository `build/playback-file-tags.*` directory. It does not build or launch the
player, open user media, alter permissions on user files, or use Finder automation.

```bash
bash Tools/PlaybackFileTagTests/run.sh
PLAYBACK_FILE_TAG_SANITIZER=address bash Tools/PlaybackFileTagTests/run.sh
PLAYBACK_FILE_TAG_SANITIZER=thread bash Tools/PlaybackFileTagTests/run.sh
python3 -B Tools/PlaybackFileTagTests/negative.py remove-color
python3 -B Tools/PlaybackFileTagTests/negative.py skip-conflict
python3 -B Tools/PlaybackFileTagTests/negative.py skip-readback
xcrun swiftc -typecheck -target x86_64-apple-macos10.15 iina/PlaybackFileTags.swift
```

The positive suite has 336 checks. Exact broken-source controls must fail only the
expected assertions: deleting the other same-color custom tag (332 checks / 1
failure, with one fewer subsequent deletion), ignoring pre-write attribute
conflicts (336 / 4), and skipping post-write readback (336 / 1). The control runner
returns success only when the verifier returns 1 with precisely those failures;
compilation errors, crashes, absent summaries, or unexpected failures do not pass.
Original source hashes are checked before and after each run. Test artifacts and
earlier failures are retained for review, not relabeled as successful runs.

## Verified semantics

- All seven colors can coexist as actual named Finder tags. Adding an already
  present color is a byte-identical no-op, including a user-defined colored tag.
- Only the explicitly selected exact tag is removed. Another tag of that same
  color remains; there is no clear-all operation.
- A default color name that conflicts with an existing differently colored or
  uncolored name is rejected, including case-only spelling differences. Global
  Finder tag definitions are never changed.
- The binary plist is read through the existing production playlist reader and
  the system's public `URLResourceValues.tagNames` API after every color addition.
- Media bytes, content modification date, `com.apple.FinderInfo`, unrelated
  attributes, and all unselected tag entries are preserved. A legacy FinderInfo
  color is reported separately and is never silently cleared.
- Deleted, replaced, changed-content, symlink, ancestor-symlink, hard-linked,
  directory, FIFO, remote URL, malformed-metadata, and denied-write cases fail
  closed. Attribute sizes/counts and individual tag sizes are bounded.
- Reads and writes run on a serial utility queue; completions run on the main
  queue. Pending write activity is registered synchronously before queueing and
  released before every completion, including failures. A controlled stalled I/O
  operation leaves the main queue responsive.

## Filesystem boundaries

Each snapshot pins the opened regular file descriptor. Its local path is walked
without following symlinks, and device/inode/birth time/content size/content
mtime are checked before and after mutation. Existing tag bytes are compared to
the snapshot before writing, and the actual written bytes are checked afterward.
No whole-file replacement or content read is needed for production tag edits.

macOS xattrs have no compare-and-swap operation. These checks reject observed
external edits, not every possible simultaneous Finder write inside the final
system-call window. The pinned descriptor prevents a replaced *new* file from
being targeted during that window. A post-write conflict is reported as
unverified; the service does not roll back over another application's newer
metadata. The snapshot identifies the file when the tag menu is read, not an
inode retrospectively recovered from the playback engine at media-open time.

The metadata representation is the same named-tag plist already decoded by the
project's file list. `ResourceProbe.swift` independently exercises Apple's public
[`URLResourceValues`](https://developer.apple.com/documentation/foundation/urlresourcevalues)
and [`setResourceValues`](https://developer.apple.com/documentation/foundation/url/setresourcevalues(_:))
against a newly created synthetic file. On the tested host, setting `labelNumber`
changes only the legacy FinderInfo label; passing suffixed strings through
`tagNames` appends another color-zero suffix. Neither operation safely expresses
the requested multi-color edits while retaining custom colored tags, so the
production service writes only the named-tag xattr through the pinned descriptor.

The suite does not claim physical Finder icon redraw, remote/network-volume
behavior, complete player UI acceptance, or successful release delivery. Those
remain separate integration and release checks.
