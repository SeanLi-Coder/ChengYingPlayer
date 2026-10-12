# Native video tools menu gate

Run from the repository root:

```sh
python3 -B Tools/NativeVideoToolsMenuTests/run.py
python3 -B Tools/NativeVideoToolsMenuTests/run.py --sanitizer address
python3 -B Tools/NativeVideoToolsMenuTests/run.py --sanitizer thread
python3 -B Tools/NativeVideoToolsMenuTests/run.py --negative-control old-guard
```

The negative control must exit nonzero: it restores the MPV-only `info.isAudio`
guard while leaving the rest of the current production predicates intact.
It must fail on a native video with empty MPV tracks, not on compilation.

The runner mechanically extracts the production menu predicate, menu action,
menu validation method, `PlaybackInfo.isAudio`, and native initial-admission
predicate. It compiles the real `PlayerState` and uses real AppKit menu dispatch.
Window, decoder metadata, and sidebar attachment are explicit recording
boundaries. All shared eligibility checks and legacy audio/album-art behavior
remain covered. No MPV track is fabricated for native playback.

This does not open the real nib, start a decoder, generate media, or prove actual
preview pixels. Full application `preview_real_tools_menu_attached` and later
preview assertions remain unchanged and must pass separately in disposable CI.
Each run keeps source/generated SHA-256 records, compiler output, test results,
and an after-run immutability check in its unique ignored `build/` directory.

The initial verified matrix contains 151 checks: normal, AddressSanitizer, and
ThreadSanitizer each passed all 151. The old-guard negative control produced four
behavioral failures (validation and actual request delivery for paused/playing
native video) while the remaining checks passed. Those results do not replace
the still-required complete App test.
