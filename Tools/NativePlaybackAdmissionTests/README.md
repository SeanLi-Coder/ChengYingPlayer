# Native admission preference regression

Run from the repository root:

```sh
bash Tools/NativePlaybackAdmissionTests/run.sh
NATIVE_PLAYBACK_SANITIZER=address bash Tools/NativePlaybackAdmissionTests/run.sh
NATIVE_PLAYBACK_SANITIZER=thread bash Tools/NativePlaybackAdmissionTests/run.sh
```

The test mechanically extracts the complete `PlayerCore.attemptNativeOpen`
method. A real FFmpeg-generated local MP4 is copied into unique owned temporary
directories, alongside synthetic subtitles and child directories. The actual
production background directory enumeration runs; preferences, MPV state, route
handoff, and decoder startup are explicit recording boundaries.

The 64 assertions cover enabled/disabled automatic sibling loading, per-open
opt-out, subtitle and child-directory checks, custom subtitle paths, watch-later,
global playlist repeat, EOF close policy, already-used/non-idle MPV, multiple input,
one destination, and preference capture before the background inventory starts.
This is admission-policy evidence, not decoding, pixel, full-App, or native-queue
acceptance. HDR and track eligibility are checked downstream in production and
are not exercised or changed here.

Every run also compiles a single-variable negative control which removes only
the `playlistAutoAdd` conjunction. It must exit 1 with exactly three named failed
assertions, including the disabled-preference route. The positive run must exit 0;
unexpected sanitizer reports or source changes fail the runner. Logs, exit codes,
generated sources, fixtures, and before/after SHA-256 records remain under the
printed `build/native-admission-tests.*` directory. No installed app, user media,
preferences, browser state, or permissions are accessed.

## Frozen verification

On 2026-10-13, production `PlayerCore.swift` SHA-256
`e1cd71918d1f5c0f3aa0954ab9e0130bbd35ab23068a9db8fcb9741db4b193d5`
passed all three modes with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` (no Homebrew
`rg` dependency). Each positive run passed 64 assertions; each single-variable
negative run failed exactly the required three assertions and exited 1. The
runner returned 0, with unchanged source hashes and no sanitizer diagnostics:

| Mode | Evidence directory under `build/` |
| --- | --- |
| Normal | `native-admission-tests.b6ZTTu` |
| AddressSanitizer | `native-admission-tests.cqCUw2` |
| ThreadSanitizer | `native-admission-tests.p5KHQ4` |

The existing `NativePlayerRouteTests` retained all 287 assertions and passed
against this Core and decoder SHA-256
`acb0f798f875daa6cab78af82ad1c3ff5d5e059033adf308c2156ab41da3a703`
in `native-player-route-tests.dylqWt`, with unchanged source hashes. Its only
fixture adaptation adds the preference key and the existing default value `true`;
it does not copy the new admission rule. This remains a rendered Core boundary
test, not complete nib/application acceptance.
