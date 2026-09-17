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

Only a newly generated, test-only CryptoKit key is used. The production signing
secret is removed from the environment, and the login Keychain is never accessed.
The fixture has its own random bundle identifier and preference domain; it does not
launch, replace, or change preferences for an installed copy of ChengYing. A local
HTTP transport exception exists only in the disposable test plist, never in the
shipping application.
