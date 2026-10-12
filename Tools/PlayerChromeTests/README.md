# Player edge-control tests

Run `bash Tools/PlayerChromeTests/run.sh` on macOS. Set
`PLAYER_CHROME_SNAPSHOT_DIR` to retain PNG snapshots outside the temporary test directory.

The native harness compiles the production `PlayerEdgeControlsView`,
`PlayerCornerControlsView`, and `TimeLabelOverflowedView`. It reads the current
`MainWindowController.xib` and reconstructs the real fragment constraint trees,
including the timeline label minimum widths, slider margins, button dimensions,
and the volume slider's required width. The fixture applies the same compact
bottom-mode spacing as the window integration: transport button gaps of 16 and
timeline top/bottom margins of 3. The seek slider uses a standard `NSSlider`;
this harness does not simulate the playback engine, A–B looping, or the
production `PlaySliderCell` drawing.

Checks cover:

- Exact layouts at widths 285, 320, 379, 380, 381, 640, and 1920, including the
  actual minimum playback-window width and both sides of the centered-transport
  transition, without conflicting or ambiguous constraints. Repeated narrow/wide
  resizing verifies that the original play button returns to the video center;
  narrow windows yield only the space needed by the right-aligned volume controls.
- Real-window screenshots in light/dark appearances and explicit 1×/2×
  rendering densities. Pixel sizes follow actual content bounds if the CI
  screen constrains the window; exact-width layout checks run separately.
- Original control identity, target/action, keyboard equivalent, seek and volume
  values, transport/mute button delivery, and clean removal from the previous
  `NSStackView`. Every transport/volume control retains its native hit surface.
- Click-through empty video space, clickable slider bounds, and hidden/faded
  controls not intercepting mouse input.
- Dynamic toolbar width and runtime accessibility updates. Reduce Transparency
  is verified by comparing pixels over two different video backgrounds, not
  merely by checking an appearance property.

All screenshots use a generated geometric background and a fictional filename;
no user-provided media is loaded or copied.
