# Simplification regression checks

Run `bash Tools/SimplificationTests/run.sh` on macOS with the Xcode command-line tools installed.

The suite compiles the production `IINACommand` availability policy without stubs. It verifies that retired native commands remain safely parseable but unavailable, while local playback, panels, PiP, playlist actions, and recoverable trash remain available.

It also parses the actual preference and main-menu XIBs to check removed bindings and outlets, retained video/audio controls, owner connections, hidden menu entries, and dangling Interface Builder references. Every shipped input preset is checked for retired commands. The actual CLI is compiled and executed to verify help and rejected legacy options.

Separately labeled source-integration assertions guard the playlist preference and toolbar customization entry points. These are structural checks, not runtime AppKit tests.

These checks complement the native video/subtitle controller tests and the full Xcode build; they do not claim to instantiate the complete preference window or test its visual layout. The CLI test uses a sibling `/usr/bin/true` symlink to satisfy the executable-presence check; the tested help and rejection cases exit before launching that fixture.
