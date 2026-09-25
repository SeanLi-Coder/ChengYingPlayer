# Real application replacement test

Run on Apple Silicon macOS with a logged-in graphical session and Xcode tools:

```sh
SPARKLE_TEST_ROOT=/path/to/SourcePackages/artifacts/sparkle/Sparkle \
  python3 -B Tools/AppUpdateIntegrationTests/run.py
```

The optional negative scenario signs a valid release feed, then changes one byte
in its DMG without changing the advertised length:

```sh
SPARKLE_TEST_ROOT=/path/to/SourcePackages/artifacts/sparkle/Sparkle \
  python3 -B Tools/AppUpdateIntegrationTests/run.py --scenario tampered-dmg
```

The real updater must discover version 2 and reject its archive with a Sparkle
signature/validation error. Assertions prohibit installation-barrier acquisition,
installation readiness, and any relaunch. The installed version must remain 1,
its Info.plist and executable hashes must be unchanged, and its full code signature
must still verify. The default `upgrade` scenario remains the positive replacement
test described below.

CI also sets `SPARKLE_INSTALLED_APP` to the built application so the test uses the
exact embedded and signed framework that will ship. It compiles against the pinned
Sparkle headers and links the copied framework at runtime.

This creates a uniquely identified, disposable AppKit app under a private temporary
directory, and runs the production update user driver against a localhost signed
feed and DMG. The two fixture versions use the production hardened-runtime
entitlements. Assertions require download, signature verification, the idle
countdown and admission barrier, on-disk replacement, and a real version-2 process
relaunch. The installed replacement is also code-signature verified.

## Incremental installation and fallback

The same real installer fixture also covers these scenarios:

```sh
SPARKLE_TEST_ROOT=/path/to/Sparkle \
  python3 -B Tools/AppUpdateIntegrationTests/run.py --scenario delta-upgrade
SPARKLE_TEST_ROOT=/path/to/Sparkle \
  python3 -B Tools/AppUpdateIntegrationTests/run.py --scenario tampered-delta
SPARKLE_TEST_ROOT=/path/to/Sparkle \
  python3 -B Tools/AppUpdateIntegrationTests/run.py --scenario mismatched-delta
SPARKLE_TEST_ROOT=/path/to/Sparkle \
  python3 -B Tools/AppUpdateIntegrationTests/run.py --scenario tampered-delta-and-dmg
```

The fixture uses the pinned SDK's `BinaryDelta create --version 4 --compression
lzma` and `sign_update`, with its ephemeral test key. Before serving a delta, it
applies it to the original fixture, verifies the resulting code signature, and
compares the full bundle's file bytes and symbolic links with the signed target.
The signed appcast advertises the source build, Sparkle executable size, and
Sparkle locales in the same format as the release builder. A shared synthetic
payload ensures that the patch is smaller than the full DMG.

- `delta-upgrade`: the HTTP server must observe exactly one delta payload request
  and no full-DMG request; the installed bundle must exactly match the full target.
- `tampered-delta`: one byte of the already signed delta is changed without
  changing its advertised size. Sparkle must reject it internally and request the
  full signed DMG, then successfully install and relaunch exactly once.
- `mismatched-delta`: the installed version-1 fixture is re-signed with a different
  resource after delta creation. Its version and Sparkle eligibility metadata
  still match, but its tree checksum does not. Sparkle must fall back to the full
  signed DMG and successfully install and relaunch exactly once.
- `tampered-delta-and-dmg`: both already signed payloads are changed. Sparkle must
  attempt the full fallback but reject that archive too, leaving the entire
  original bundle intact with no installation barrier acquisition or relaunch.

In both successful fallback cases, the server checks the original installed tree
and journal immediately before serving the full archive. A failed delta must not
modify the installed app, acquire the install barrier, or enter install readiness.
These assertions use actual HTTP requests and real Sparkle events, not mock
download counters or synthesized phase transitions.

## User data retention

Every installation scenario seeds typed preferences in the disposable app's
random bundle domain: HDR, volume, playback speed, shortcut configuration, a
synthetic bookmark, folder sorting, a credential-free proxy value, and explicit
automatic-update opt-outs. It also creates synthetic settings, shortcut, bookmark,
download-history, and model files in a temporary Application Support tree outside
both app bundles. The original process verifies these values before termination;
the actual replacement process verifies all values and file SHA-256 digests after
relaunch. The runner independently checks that no support file is changed, added,
or removed. The rejection scenarios verify preferences before their orderly exit
without resetting them.

The random preference domain is deleted only during test cleanup. No real
ChengYing preference domain, user model, browser profile, or user media is read,
modified, copied, or removed. This fixture verifies installation retention; the
separate native preference tests exercise production first-launch migrations.

## Real driver observation

The fixture wraps the unchanged production user driver with a protocol-conforming
observer. Every callback is forwarded to the real driver; state is read immediately
after it returns and before invoking a potentially reentrant Sparkle reply. Journal
events are never synthesized from expected state. This makes short download phases
observable even if localhost delivery and extraction happen between timer ticks.
Assertions also require that the production download window was actually visible.
No artificial network delay or relaxed download/security assertion is used.

All real scenarios first run a deterministic, same-main-actor-turn regression:
the real driver enters downloading, receives all advertised bytes and begins extraction
without giving the run loop a chance to sample the intermediate phase. The callback
observer must capture both transitions while the former 10 ms polling approach
demonstrably misses downloading. Reentrant acknowledgements must be observed first
and forwarded exactly once. Run only this bounded regression with:

```sh
SPARKLE_TEST_ROOT=/path/to/SourcePackages/artifacts/sparkle/Sparkle \
  python3 -B Tools/AppUpdateIntegrationTests/run.py --scenario phase-observer
```

Only a newly generated, test-only CryptoKit key is used. The production signing
secret is removed from the environment, and the login Keychain is never accessed.
The fixture has its own random bundle identifier and preference domain; it does not
launch, replace, or change preferences for an installed copy of ChengYing. A local
HTTP transport exception exists only in the disposable test plist, never in the
shipping application.
