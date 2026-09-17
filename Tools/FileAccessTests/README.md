# File access guide regression tests

Run `bash Tools/FileAccessTests/run.sh` on an Apple Silicon Mac with an available
window server. The fixture compiles the real guide controller, coordinator,
shared AppKit styling, and update admission lock in Swift 5. It also typechecks
the same sources for Intel macOS 12. No production application is launched.

The tests cover first-interactive-launch persistence, noninteractive launch
exclusion, blocked presentation, manual reopening, native close and deinit
lease cleanup, repeated-show lease balance, versioned Settings-link fallbacks,
explicit-only mock actions, and the distinction between showing a guide and
actually granting system permission. A fixture `NSApplication` subclass supplies
activation and modal ownership to exercise the real notification-driven launch
scheduler, including attached sheets, duplicate scheduling, cancellation, and
weak-lifetime cleanup, without activating the test app or opening a real chooser.
A UUID-named defaults suite is removed
after each run; real application preferences and privacy databases are never
opened or changed. Every Settings and Finder callback is replaced with a fake.
Static integration assertions additionally inspect the actual AppDelegate and
welcome entry points, command-line and termination guards, Xcode target source
and localization membership, matching translation keys, and CI registration.

Both English and Simplified Chinese run from a localized fixture app bundle.
Native, 1x, and 2x light/dark PNGs validate actual content bounds, nonempty
rendering, and different appearance pixels. The tests reject ambiguous or
conflicting Auto Layout constraints, clipped explanation text, out-of-window
controls, and overlapping buttons, including the Settings-link failure state.

Set `FILE_ACCESS_SNAPSHOT_DIR` to retain screenshots outside the disposable
fixture directory, for example:

```sh
FILE_ACCESS_SNAPSHOT_DIR=/tmp/chengying-file-access-snapshots \
  bash Tools/FileAccessTests/run.sh
```

These tests intentionally do not check or change Full Disk Access, trigger a
system privacy prompt, launch System Settings or Finder, or infer permission
from a stored preference. They validate the application's explanation and
lifecycle behavior, not macOS's permission decisions.
