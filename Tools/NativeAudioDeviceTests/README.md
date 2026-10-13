# Native audio-device compatibility routing

This suite extracts the production `PlayerCore.setAudioDevice`, its capability
and selection getters, `AppDelegate.menuSelectAudioDevice`, and the actual
`MenuController.updateAudioDevice` body. It reuses the native Session, decoder,
transport, Core owner state machines, real libmpv, and queue installer from the
CoreQueue/GenericHandoff test services. It does not install or launch a player app.

The audio-device enumeration is an explicit two-item fixture. The unused MPV
handle is configured with an unavailable test device; the action selects `auto`.
This proves when the real MPV property changes, not that a physical output device
or audible playback works. MPV uses null outputs, and synthetic native audio is
silent. Application/window services and event forwarding remain test boundaries.

The queue event adapter forwards actual MPV events. It can hold an actual loaded
or restart callback to test cancellation; it does not invent readiness. Queue
stop quiescence uses the existing explicit controller service, which requires
actual MPV idle, absent active path, and a cleared playlist before acknowledging
the Core stop. This is not full production MPVController or whole-app acceptance.

## Run

```sh
bash Tools/NativeAudioDeviceTests/run.sh
NATIVE_PLAYBACK_SANITIZER=address bash Tools/NativeAudioDeviceTests/run.sh
NATIVE_PLAYBACK_SANITIZER=thread bash Tools/NativeAudioDeviceTests/run.sh
NATIVE_AUDIO_DEVICE_NEGATIVE_CONTROL=direct-idle-write bash Tools/NativeAudioDeviceTests/run.sh
NATIVE_AUDIO_DEVICE_NEGATIVE_CONTROL=idle-menu-state bash Tools/NativeAudioDeviceTests/run.sh
NATIVE_AUDIO_DEVICE_NEGATIVE_CONTROL=drop-busy-guard bash Tools/NativeAudioDeviceTests/run.sh
```

Run serially with other native GUI/session tests. `NATIVE_AUDIO_DEVICE_BUILD_ONLY=1`
compiles without running playback. Artifacts go to a unique
`build/native-audio-device.*` directory. Source manifests must match before/after,
and generated files are independently hashed. Negative controls mutate only
generated production extracts; the verifier requires the exact failure multiset
and assertion count, with no sanitizer errors.

The 90 checks cover synchronous idle initialization, real single-file and
two-file queue handoff, menu state before/during/after handoff, reentrant choices,
and stop plus same-path reopen during capture, load, and exact seek for both
single-file and queue owners. `NSMenu.update()` must not re-enable busy entries.
Image-only menu behavior is preserved. Rotation/enqueue-specific transitions and
physical output-device switching are not separately exercised here.

## Local evidence, 2026-10-13

Production Core SHA-256:
`14d8d1404bfc6483a2de39bfcaf353e0f10c01af90a73ce60ba6dc076415f0b1`.
Menu SHA-256:
`4193310daf71b61d6cc2d12c3db3cf3d1c667931b506c9895289853e441141fa`.

- `D5ogVc`: ordinary, 90 passed / 0 failed.
- `8tUPGl`: AddressSanitizer, 90 passed / 0 failed.
- `2odrPO`: ThreadSanitizer, 90 passed / 0 failed.
- `g0gHvg`: `direct-idle-write`, exactly 35 of 84 checks failed.
- `Iwdl7e`: `idle-menu-state`, exactly 10 of 90 checks failed.
- `Mn1DhV`: `drop-busy-guard`, exactly 5 of 90 checks failed.

All six runs have identical source manifests, unchanged source-before/after,
valid generated-file hashes, and runner exit 0. Each negative binary exits 1;
only the precise expected failure multiset is accepted by the verifier. Ordinary,
ASan, and TSan Core extracts are byte-identical. No sanitizer findings were emitted.
The direct-write control does not enter handoff, so its six callback-only checks
are absent and its expected count is 84, not 90. No checks are skipped in the
ordinary, ASan, or TSan run.

Preserved discovery evidence:

- `t9BVrJ`: original production, 31 passed / 16 failed. Native selection wrote
  the idle MPV property without any compatibility handoff; its menu advertised
  that inactive device. The original suite had fewer queue cancellation checks.
- `7ZrwLh`: compile-only failure because the new extractor omitted the production
  `hasPendingURLPlaylistEnqueue` accessor. It was added to the extract, not stubbed
  to report a successful handoff.
- `VY7PN3`: 51 passed / 2 failed. The event service lacked real `idle-active`
  observation, so stop followed by queued reopen never completed. The adapter now
  observes and forwards the actual flag event; production stop logic was unchanged.
- `gmIBLE`, final-script `YxquVl`, and ASan `W3xMJ1`: earlier 59-check suite passed.
  Its exact controls were `5R0U3e` (20/53 failures), `lB2XXW` (7/59), and
  `jcoL4Q` (5/59). These do not substitute for the expanded 90-check results.

The default playback backend and release/version settings are unchanged.
These results do not imply a complete application build or released update.
