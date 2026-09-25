# Signed update regression tests

Run on macOS 12 or later with Xcode tools and the project's resolved Sparkle 2.10 artifact:

```sh
SPARKLE_TEST_ROOT=/path/to/DerivedData/SourcePackages/artifacts/sparkle/Sparkle bash Tools/SparkleUpdateTests/run.sh
```

The suite generates an ephemeral CryptoKit Ed25519 seed in a private temporary directory,
builds a signed ARM64 stub application and real DMG, and invokes Sparkle's actual
`generate_appcast` and `sign_update` tools. It never accesses the login Keychain or
production signing key. Only the official tools receive the disposable seed via stdin.

Production verification uses CryptoKit with the public key from the application plist.
Tests reject changed feed/archive bytes, wrong keys, unsigned or ambiguous envelopes,
incorrect versions, external repositories, incompatible architecture/OS requirements,
extra install policies, external release notes, and insecure application settings.

The macOS release job additionally verifies the new feed using the previous stable
version's public key and compares it with the built application. Publication checks
the old and new source configurations again to preserve the bundle identity,
stable feed URL, public key, default automatic checks and visible download policy.

These policy and delivery regressions need only Python 3.11+ and do not access the
network, production credentials, or installed applications:

```sh
python3 -B Tools/SparkleUpdateTests/test_release_policy.py
python3 -B Tools/SparkleUpdateTests/test_release_delivery.py
python3 -B Tools/SparkleUpdateTests/test_delta_assets.py
```

Delivery tests cover resumable missing-asset upload, bounded retries, ambiguous
upload success, immutable existing assets, publication races, stale public feeds,
and full anonymous DMG download verification including same-size corrupt bytes.
The actual publication job uses `other/release_delivery.py`: it refuses conflicting
remote assets instead of deleting them, and does not finish successfully until the
public latest release, installed-app feed and complete DMG/delta bytes match the build.
These checks do not replace the real Sparkle install-and-relaunch integration test.

The release feed is the sixth atomic draft-release asset, beside the existing DMG,
corresponding source archive, two checksums and source manifest. Signed feed content
must not be edited after signing. The feed's archive URL is version-pinned, while the
application's feed URL points to this repository's latest release. Ad-hoc code signing
does not constitute Apple notarization.

## Incremental updates

The release builder authenticates the previous stable DMG before mounting it and
uses pinned Sparkle `BinaryDelta` format 4. It applies the patch to a private copy,
compares every file, mode and symlink to the target, and verifies the reconstructed
code signature. The current full DMG must contain exactly that target. Only a patch
smaller than the full archive is advertised; the signed full archive always remains.
Older/skipped versions, modified applications and invalid patches may require a full
download. The last stable release is the only delta base currently generated.

Run real builder regressions with the same SDK environment:

```sh
SPARKLE_TEST_ROOT=/path/to/Sparkle python3 -B Tools/SparkleUpdateTests/test_delta_builder.py
```

The signed-feed suite rejects missing, altered, duplicated, future-base or off-site
deltas, ambiguous nesting, unsupported attributes, symlinks and incorrect sizes.
Builder tests use disposable signed apps and DMGs, including a same-version but
different-content full archive. Delivery tests require every advertised delta and
checksum in addition to the six base assets, and download each public patch in full.
Historical base authentication may ignore obsolete delta payloads only after checking
their metadata and authenticating the previous full DMG; new releases verify all
payload signatures. No CLI bypass exists for new-release delta verification.

`Tools/AppUpdateIntegrationTests` separately proves actual delta-only download,
full fallback and double-corruption rejection using Sparkle's real installation path,
and checks synthetic preferences and external support files across relaunch.
