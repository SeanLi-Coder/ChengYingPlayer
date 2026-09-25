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

Preference regressions recreate `UserDefaults` with the same random test domain
for three simulated later-version launches. They verify new-install automatic checks,
explicit user opt-outs both before and after the first migration, visible downloads
(`SUAutomaticallyUpdate = false`), and unrelated user preferences all persist.
The retained-domain fixture compares every stored key, type, and value, including
HDR, control layout, volume, a custom keybinding path, synthetic bookmark bytes,
a credential-free proxy URL, and sorting settings. No real preferences are read.
The silent-downloader flag remains false as the existing safety policy: this player
requires visible download progress and waits for protected work before replacement.
It is not a reset of the user's automatic-check choice. Command-line disable remains an
argument-domain override: it does not overwrite stored settings or consume the
migration, which runs on a later normal launch. These tests simulate preference
reuse; they do not claim to perform sequential application replacements.

Native AppKit screenshots cover light download progress, dark task waiting, and
the restart countdown. Actual view bounds and Auto Layout diagnostics are checked.
These tests never contact a release feed, replace an app, or terminate playback.
Release signing and end-to-end replacement are covered separately by release tests.
