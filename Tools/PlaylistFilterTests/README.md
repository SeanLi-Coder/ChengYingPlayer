# Playlist filter interaction regression

Run `bash Tools/PlaylistFilterTests/run.sh` on macOS. The script mechanically
extracts the production playlist controller's identity mapping, filter rebuild,
drag-and-drop, removal, double-click, context-menu, and subtitle-popover methods.
It compiles the actual playlist identity and Finder metadata models and performs
an additional Intel/macOS 10.15 typecheck.

Only playback and external presentation boundaries are replaced. Tests use real
AppKit table views and a uniquely named, isolated pasteboard; they never modify
the user's general clipboard, preferences, files, or an actual playback queue.
No application windows are presented.

Coverage includes hidden entries, duplicate paths, ID/path replacement, live
queue reorder, stale multi-selection, stopped playback, external insertion
anchors, context-menu identity capture, chapter independence, subtitle targets,
mid-drag queue/filter changes, malformed drag data, and normal unfiltered
reordering. The extraction fails when its production boundaries change, rather
than silently testing an outdated hand-written implementation.
