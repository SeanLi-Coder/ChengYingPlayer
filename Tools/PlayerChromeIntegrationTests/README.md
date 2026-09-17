# Native player-chrome integration tests

Run `bash Tools/PlayerChromeIntegrationTests/run.sh` on macOS.
Set `PLAYER_CHROME_INTEGRATION_SNAPSHOT_DIR` to retain the native PNG captures.

The extractor compiles the current production implementations of:

- `MainWindowController.setupOnScreenController`
- `MainWindowController.setupSidebarPanelLayout`
- `MainWindowController.updateEdgeControlsLayout`
- `MainWindowController.setupOSCToolbarButtons`
- The mode-dependent production `minSize` property
- `OSCToolbarButton.setStyle`
- `PlaylistViewController.installSortControls`
- The real playlist `downShift`, `useCompactTabHeight`, and runtime `rowHeight`
  assignment from `viewDidLoad` (not only the smaller value in the XIB)

The harness reuses the native edge/corner components and reads the real XIB
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
