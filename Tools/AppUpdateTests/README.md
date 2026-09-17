# Native application update tests

Run with the real Sparkle 2.10 artifact, not a protocol stub:

```sh
SPARKLE_FRAMEWORK_DIR=/path/to/Sparkle.xcframework/macos-arm64_x86_64 \
APP_UPDATE_SNAPSHOT_DIR=/tmp/chengying-update-snapshots \
bash Tools/AppUpdateTests/run.sh
```

Set `APP_UPDATE_TEST_LANGUAGE=zh-Hans` (or `zh-Hant`) to inspect localized layouts.

The suite compiles every coordinator/user-driver/window/policy production file
against Sparkle's real protocol and invokes its download, extraction, readiness,
error, and termination-retry callbacks. Activity and time are injected so races
are deterministic. It covers one-time preference migration, command-line disable,
read-only installation locations, content-length changes/overflow, hidden versus
cancelled windows, already-installing updates, busy countdown reset, asynchronous
barrier races, safe retry after termination veto, and quiet background failures.

Native AppKit screenshots cover light download progress, dark task waiting, and
the restart countdown. Actual view bounds and Auto Layout diagnostics are checked.
These tests never contact a release feed, replace an app, or terminate playback.
Release signing and end-to-end replacement are covered separately by release tests.
