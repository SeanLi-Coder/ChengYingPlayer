# Frozen helper signing regression

Run on macOS after building both frozen helpers and FFmpeg:

```sh
bash Tools/HelperSigningTests/run.sh
```

To inspect binaries from a copied application, pass `--helpers-directory` with its
`Contents/MacOS` directory. Tests never re-sign the input helpers. Every signing
mutation uses a private temporary copy; input hashes, permissions, and modification
times are checked afterward.

The test reproduces Xcode's `CodeSignOnCopy` command, verifies that each helper has
only the library-validation exception it needs, runs both helper protocols, and
repeats verification after signing a containing application. No model downloads or
network operations are requested.

A stripped-entitlement helper must fail the static policy on every host, including
GitHub Actions. Its actual launch is also required to fail on local hosts that
report enabled SIP. GitHub runners may relax runtime enforcement, so a successful
launch there must never substitute for the static entitlement check. No system
security settings or quarantine attributes are changed.
