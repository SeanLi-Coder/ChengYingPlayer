# Native video viewport regression tests

Run on macOS with Command Line Tools:

```sh
bash Tools/VideoViewportTests/run.sh
```

The suite compiles the complete production `VideoToolsPlayerBridge.swift`,
`VideoToolsShortcuts.swift`, `VideoToolsLoopPolicy.swift`, `PlayerState.swift`,
`MPVOption.swift` and `MPVProperty.swift`. The viewport model, arithmetic and
player-property updates are never copied into the test fixture.

`extract.swift` mechanically extracts the complete production `keyDown(with:)`
and `handleVideoToolsShortcutEvent(_:)` methods into a small native controller.
Only application dependencies and mpv access are recording boundaries. Changes
to extraction boundaries fail explicitly. Separate source-wiring assertions
check the safe per-load reset before drawing and all three mpv per-file reset
options; these assertions are not presented as full file-loading tests.

Coverage includes:

- Linear zoom steps, imported arbitrary zoom, limits, invalid values, four pan
  directions, consistent displacement, edge clamping, recentering and reset.
- Real production state guards for loaded, paused, audio-only, unloaded and
  shutting-down players, with no unsafe mpv calls.
- Only the three display properties change; playhead, speed, pause, rotation and
  A-B loop state remain unchanged.
- Actual AppKit `NSEvent`, `NSWindow`, text view, field editor and attached sheet
  objects exercise the native routing. The suite checks key-window ownership,
  focus protection, interactive-mode protection, OSD localization and fallback
  handling for unrelated keys.
- An observable legacy window-size binding proves the new shortcut takes
  priority. Window frames are compared throughout zoom and pan operations.
- The same checks run with English and Simplified Chinese resources, and the
  sources are also type-checked for Intel macOS 10.15.

The suite creates only temporary test windows and build output. It does not
inject global input, read or change user settings, open user media, or claim to
validate actual mpv rendering. Live-renderer coverage belongs in `Live/`.

Set `VIDEO_VIEWPORT_SOURCE_ROOT` to another checkout for source mutation tests.
The source-only app release restriction is unchanged.
