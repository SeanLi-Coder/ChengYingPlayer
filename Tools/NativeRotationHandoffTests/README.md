# Controlled permanent-rotation handoff regression

Run `bash Tools/NativeRotationHandoffTests/run.sh`. Optional
`ROTATION_HANDOFF_SANITIZER=address` or `thread` applies the sanitizer to every
positive and negative executable. The test opens and retires one short-lived CLI
`NSWindow`; it does not create an application bundle or use personal media.

`ROTATION_HANDOFF_BUILD_ONLY=1` compiles the positive fixture and all four
negative variants without executing any binary or creating a window. This mode
checks extraction and compilation only, not behavior or negative-control failures.

The extractor copies production `PlayerCore` rotation ownership, compatibility
capture, retirement, open arbitration, pause/resume, three seek forms, shutdown
and stop methods. It copies the real window shortcut/play-button handlers and
the panel/quick-settings forwarding entry. The production helper, shortcut
resolver, loop policy and rotation coordinator are compiled directly. Source
landmarks must occur exactly once. Private visibility is removed only in the
generated test compilation.
The controlled legacy-open boundary starts after the production route and
generic-owner phase transition; it does not add a second route increment.

Native clock capture, asynchronous renderer shutdown, MPV load/restart events,
unrelated UI work and the export task service are controlled recording
boundaries. Three original lifecycle sub-blocks are copied verbatim, not the
entire `fileStarted`, `fileLoaded` or `playbackRestarted` implementations. The
panel application boundary submits to the real coordinator but does not imitate
the complete `VideoToolsViewController`; its existing full-VC suite remains
required. This is not a full application, actual rendering or exported-file
validation. Constructed `NSEvent` values enter the production handler; there is
no OS keyboard injection.

The bounded timeline covers:

- Multiple physical left-command rotations during capture, `.stopping` and
  `.loading`, including repeated keys, right-command rejection and unrelated-key
  admission. Panel and shortcut inputs share one compatibility request.
- Exactly-once delivery after a matching restore position, stale completions,
  same-URL user reopen, stop/shutdown ordering, preview/capture failure and a
  controlled invocation of the real 20-second watchdog action. It does not
  claim natural wall-clock expiry was measured for that watchdog.
- Action cancellation separated from same-media playback restoration. Sleep's
  actual `pause()` entry, consecutive play-button actions, exact/relative/percent
  seeks, captured duration, A/B bounds, position, pause, volume, rate and viewport
  are retained through drain/load/restart. Commands are not sent to the closing
  native backend. Old-position restart cannot complete a newer target.
- After cancellation, a new rotation is rejected during drain/loading. Once MPV
  is loaded it is an independent ordinary coordinator request; it does not revive
  the old action or overwrite transport restoration. No new navigation queue or
  second compatibility transition is introduced.

Four single-variable negative controls must compile and exit exactly 1 with
their specific assertion: remove transient rotation admission; reinstall a
captured stale restore; accept the wrong internal restore ID; or discard playback
state together with the cancelled export action. A crash, compile failure,
watchdog kill or unrelated assertion is not a passing negative control.

Each invocation records the base commit, sanitizer mode, full production/test
input SHA-256 manifest and generated source SHA-256 manifest. The EXIT trap also
checks input stability on failure and preserves the original nonzero result.
Logs contain only synthetic numeric/state assertions, not media or credentials.

This slice retains captured volume, rate and viewport; it does not add or verify
new volume/rate/viewport edits during the transition. Default native admission,
media decoding, app installation, signing and release behavior are unchanged.
