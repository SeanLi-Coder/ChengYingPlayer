# Native player-chrome integration tests

Run `bash Tools/PlayerChromeIntegrationTests/run.sh` on macOS.
Set `PLAYER_CHROME_INTEGRATION_SNAPSHOT_DIR` to retain the native PNG captures.

The extractor compiles the current production implementations of:

- `MainWindowController.setupOnScreenController`
- `MainWindowController.setupSidebarPanelLayout`
- `MainWindowController.updateEdgeControlsLayout`
- The production playlist-height preference getter and four lower-edge resize
  methods, including their real native `PlayerSidebarResizeHandle`
- `MainWindowController.setupOSCToolbarButtons`
- The mode-dependent production `minSize` property
- `OSCToolbarButton.setStyle`
- `PlaylistViewController.installSortControls`
- The real playlist `downShift`, `useCompactTabHeight`, and runtime `rowHeight`
  assignment from `viewDidLoad` (not only the smaller value in the XIB)

The harness reuses the native edge/corner/resize components and reads the real XIB
fragment constraints. Its playlist fixture reconstructs the real header, tab,
scroll-view, and footer hierarchy, with the production `PlaylistSortControls`.
Placeholder symbols and synthetic table rows avoid loading user media or the
complete application's asset catalog. Playback-engine behavior, fullscreen
transitions, hide timers, and sidebar animation lifecycle are covered elsewhere;
this harness only sets the fullscreen-layout state.

It exercises repeated bottom/floating/top/bottom transitions at requested sizes
285×120, 320×240, 640×400, and 1920×1080. Assertions verify compact-mode minimum
content size, video-surface bounds, toolbar ordering and identity preservation,
restoration of legacy sidebar constraints, no duplicate fadeable controls, a
sidebar entirely below the toolbar and above the footer, and enough actual
playlist viewport height for at least one row. It also rejects unexpected window
growth caused by a sidebar's optional preferred-height constraint.

The native AppKit window may be constrained by the CI screen. Tests compare
content geometry to actual bounds and separately assert that small requested
windows expand only to the documented compact-mode minimum.

The isolated height-memory cases override only the test window's
`constrainFrameRect` to keep a full 900-point layout surface even on short CI
screens. They assert its actual content bounds before testing exact 600-to-690
heights. The ordinary layout matrix retains AppKit's physical-screen constraint.
All production content constraints, grip tracking, viewport checks, and explicit
small-window clamping still execute unchanged. Each height phase reports actual
content, sidebar, maximum height, preference, and physical-screen geometry.

Height cases route a real native lower-edge hit test through production handle
`mouseDown`, `mouseDragged`, and `mouseUp` events. They verify a 600-to-690-point
downward drag with an anchored top, unchanged video/window geometry, balanced
interaction callbacks, both queue and folder viewports, and a reserved grip strip.
Mouse release saves only the height into an isolated UUID `UserDefaults` suite.
A newly constructed window and an independent child process both restore it;
the child never opens the installed player's domain or any user media. Invalid
stored heights fall back to the production default. Small-window clamping and
fullscreen layout preserve the larger saved choice, and growing the window
restores it. Mode switches, window closure, duplicate presses, and late releases
cancel tracking safely; settings keeps its compact non-resizable panel.

Set `PLAYER_CHROME_INTEGRATION_SNAPSHOT_DIR` to retain both the layout matrix and
the stretched queue/folder screenshots. Native screenshots are image files;
this runner does not create or register a test application bundle.
