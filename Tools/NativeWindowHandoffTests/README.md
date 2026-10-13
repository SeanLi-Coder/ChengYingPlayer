# Native window-state compatibility handoff

The suite extracts the production Core compatibility owner, open/load/restart
methods, window-option projection, and `checkUnsyncedWindowOptions`. The native
Session, decoder, transport, and libmpv are real. `fsState` and `isOntop` use the
production declarations; both superclass and subclass on-top methods are extracted
unchanged except the superclass call name. The on-top assertion reads the actual
test `NSWindow.level`.

The fixture does not animate macOS Spaces. Its explicit fullscreen-toggle service
records reconciliation requests and changes the production fullscreen state. UI
chrome, the rotation-export delivery, and surrounding app/event services remain
explicit boundaries inherited from the CoreQueue/GenericHandoff fixtures. MPV
uses null outputs; native audio is synthetic and silent. These are not complete
App, physical-display, audible-output, or Spaces-animation acceptance results.

## Run

```sh
bash Tools/NativeWindowHandoffTests/run.sh
NATIVE_PLAYBACK_SANITIZER=address bash Tools/NativeWindowHandoffTests/run.sh
NATIVE_PLAYBACK_SANITIZER=thread bash Tools/NativeWindowHandoffTests/run.sh
NATIVE_WINDOW_NEGATIVE_CONTROL=drop-projection bash Tools/NativeWindowHandoffTests/run.sh
NATIVE_WINDOW_NEGATIVE_CONTROL=swap-window-flags bash Tools/NativeWindowHandoffTests/run.sh
NATIVE_WINDOW_NEGATIVE_CONTROL=unowned-projection bash Tools/NativeWindowHandoffTests/run.sh
NATIVE_WINDOW_NEGATIVE_CONTROL=mark-initial-fallback bash Tools/NativeWindowHandoffTests/run.sh
```

Run serially with other GUI/native Session tests. `NATIVE_WINDOW_BUILD_ONLY=1`
only compiles. The runner stores pre/post source identities, generated-file/media
hashes, explicit compiler and child exit codes, and a final wrapper status in a
unique `build/native-window-handoff.*` directory. Negative controls mutate one
generated production fragment, require child exit 1, and accept only the exact
expected assertion multiset and summary; sanitizer failures are never accepted.

The scenarios cover admitted generic, queue, rotation and URL-enqueue owners;
both independent fullscreen/on-top combinations; actual libmpv properties before
the first load command; the latest state changed during asynchronous retirement;
stop and same-path reopen during capture/retirement; ordinary MPV configuration;
asynchronous subtitle-inventory fallback; and a real multi-audio Session that
falls back before media admission. Real worker barriers verify entry, continued
blocking, explicit release, successful wait result and exit. A timed-out barrier
cannot masquerade as the claimed interleaving.

## Preserved discovery evidence, 2026-10-13

- `uYII5O`: original production, 24 passed / 14 failed. The first four generic /
  queue cases reproduced stale MPV fullscreen/on-top flags before load, unwanted
  fullscreen reconciliation, and a real window lowered while its on-top indicator
  remained true. This initial suite did not yet contain the later owner/cancellation
  matrix.
- `brXKNN`: extended fixture compile-only; no playback result is claimed.
- `YF3mWo`: first fixed candidate, 204 passed / 0 failed. Core SHA-256
  `17b804df90441d367e88691a4c74552c31761aee7ef0a1ccfc4523d5d2247cfe`;
  source-before/after and generated hashes validated. This precedes moving the
  unchanged helper outside the declaration span and the multi-audio fallback test.

## Final candidate evidence

Production Core SHA-256:
`fbbc0af832e9525d1ad96ede021bcf6000f28362499cb7f775906d074b6c5c46`.
CoreQueue extractor SHA-256:
`055e8737e533ab3ac6e0aeff960e3213c9cf7639d351a57c66908b3db6d06062`.

- `WXqznn`: ordinary, 208 passed / 0 failed.
- `Jxis2K`: AddressSanitizer, 208 passed / 0 failed.
- `UZ5JTr`: ThreadSanitizer, 208 passed / 0 failed.
- `1y8fVf`: independent ordinary rerun by the primary agent, 208 passed / 0
  failed, with the final verifier manifest and matching source/generated hashes.
- `3YdzqP`: `drop-projection`, exactly 174 passed / 34 failed.
- `Rbxsiy`: `swap-window-flags`, exactly 168 passed / 40 failed.
- `cE2PyS`: `unowned-projection`, exactly 205 passed / 3 failed.
- `LG8wi8`: `mark-initial-fallback`, exactly 207 passed / 1 failed.

Each run compiled successfully, retained matching pre/post source identities,
validated generated hashes, and exited with wrapper status 0. Positive children
exit 0; negative children exit 1 and their exact verifier exits 0. No sanitizer
findings were emitted. All three positive Core extracts are byte-identical:
`d69db876587a9b2439e7acd95b8e248f68db8c31ffeed7401c9c20ced6733b67`.

The three positive source manifests differ from the final negative manifests in
one file only: the non-compiled `verify_negative.py`, from `ecf5add0` to `0768d075`.
Production, extractor, runner and test assertions did not change. The initial
`swap-window-flags` run `p7r9fv` was correctly rejected by that older verifier
(168/40, wrapper 1), whose expected failure count incorrectly included four
window-level assertions. Reconciliation queues the fullscreen toggle before the
on-top change; once fullscreen, the production on-top setter refuses to lower
the window. The existing floating level therefore remains intact even though
fullscreen and MPV flags are wrong. Only this negative expectation was corrected;
no positive assertion, deadline or production code was relaxed. `4w4B4v` preserves
the earlier accepted drop control (174/34) before that verifier-only correction.

The default playback backend, release/version, and installed application are
unchanged. Complete application and actual Spaces acceptance remain separate.
