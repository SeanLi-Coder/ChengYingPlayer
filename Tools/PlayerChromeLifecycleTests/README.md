# Player chrome lifecycle regression tests

Run `bash Tools/PlayerChromeLifecycleTests/run.sh` on macOS with Command Line Tools.
The suite compiles the current production show/hide, timer, mouse-move,
interaction, sidebar switching, and close method bodies from
`MainWindowController.swift`. It directly compiles `PlayerChromePolicy.swift`.
The production fullscreen-transition refresh and real `PlayerState` are also
compiled. Extraction asserts integration in all four fullscreen success/failure
callbacks; dynamic titlebar/additional-info membership, stale fades, inactive
players, disabled UI, and legacy-toolbar hover have executable regression cases.

Only private visibility and OS boundaries are adapted: animations apply their
target properties immediately while completion callbacks remain individually
controllable, pointer/button state is injected, cursor changes are recorded,
and close-position preferences use an isolated defaults suite. State-machine
branches, generation tests, sidebar content changes, and timer methods are not
rewritten. AppKit views, hierarchy, constraints, coordinate conversion, timers,
and responder types remain real.

The suite targets stale animation completions, window closing, stable shown
controls, nested interactions, pointer and mouse-button guards, sidebar editing,
non-destructive idle hiding, explicit sidebar closing and switching, migration
idempotence, retention of pre-migration control preferences and launch arguments,
registered defaults without needlessly persisting them, visible hit testing, and
bounded auto-hide delay. All preference cases use a temporary test domain, not
the user's player settings. It type-checks for
Intel macOS 10.15 and runs the host binary with Address Sanitizer.
