# Player chrome interaction checks

Run `bash Tools/PlayerChromeInteractionTests/run.sh` on macOS with a WindowServer
session. The suite compiles the complete, unchanged production `PlaySlider`,
`VolumeSlider`, and `PlaySliderLoopKnob` classes. Intel macOS 12 typechecking is
included. AppKit decodes a locally generated slider archive through the production
initializer, and real windows exercise hierarchy moves, hiding, and closing.

The native blocking `NSSlider.mouseDown` tracking loop is temporarily replaced at
the Objective-C superclass boundary with a deterministic callback and restored
after every case. This tests the actual production override's begin/super/defer/end
ordering without injecting global mouse input. The callback also reparents and
detaches the real controls during tracking. Main-window interaction counters,
playback cell drawing, and unrelated preferences are boundary doubles; this suite
does not claim to test the main-window auto-hide policy or native slider seeking.

Cases cover balanced progress/volume interactions, retained source-window
ownership, safe mini-player handling, the retained Tahoe override, repeated A-B
starts and ends, off-window dragging, hiding a knob or its ancestor, removal from
a window, window closure, and a late mouse-up after cleanup. No windows are shown,
media opened, preferences persisted, or user clipboard accessed.
