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

The release feed is the sixth atomic draft-release asset, beside the existing DMG,
corresponding source archive, two checksums and source manifest. Signed feed content
must not be edited after signing. The feed's archive URL is version-pinned, while the
application's feed URL points to this repository's latest release. Ad-hoc code signing
does not constitute Apple notarization.
