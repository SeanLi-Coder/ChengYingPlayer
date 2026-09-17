# Source-built playback distribution proof

```sh
bash Tools/PlaybackDistributionTests/run.sh
SOURCE_CACHE_DIR=/absolute/verified-source-cache \
  python3 other/verify_playback_distribution.py /absolute/deps
```

The production verifier fails closed if the recorded source inputs differ from the **complete** repository playback locks plus the five shared subtitle-library locks, including the pinned Jinja/MarkupSafe templates and Vulkan-Headers needed only during compilation. These build inputs add no Python or Vulkan runtime requirement to the player. The verifier checks the nine published dylib hashes, ARM64-only architecture, install names, dependency closure, runtime search paths and code signatures; it ignores unused extra files in `deps/lib`. It also checks the matching nine-directory SDK header checksum inventory, explicit SDK/compiler/deployment records, and the FFmpeg/mpv/libplacebo configuration records. No commands recorded in a build manifest are executed.

Original notices in `playback-build-record/licenses` must match every `COPYING*`, `LICENSE*`, `LICENCE*`, `COPYRIGHT*`, `NOTICE*`, `AUTHORS*`, and `FTL.TXT` file from every checksum-verified locked source archive, including nested notices and preserving case and bytes. Empty, missing, additional old-version, altered or linked records fail. Source archives are read without extracting them or downloading anything. `SOURCE_CACHE_DIR` defaults to the supplied dependency directory's `sources` child.

The ordered patch manifest and copied patch bytes must match `other/patches`.
Original affected-file hashes are checked against the pinned archives; modified
source copies must match the separately locked post-patch hashes. Missing,
reordered, linked, extra or changed patches and forged source hashes are rejected.
Synthetic archive fixtures inject only their explicit source/hash boundary into
the Python verifier; the release CLI always uses the checked-in production locks
and never executes record contents.

The test suite supplies **explicit synthetic source/archive and native-tool boundary mocks**. It does not claim to build real libmpv, verify a real signature, or launch the complete player. Tests exercise the actual parser and verification policy with immutable fixtures and failures for substituted libraries/SDKs, missing SDK metadata, changed versions, duplicate/missing source records, wrong license contents, corrupt archives, nonfree/autodetected options, external dependencies, old universal binaries, signature failure, path traversal, and a record containing shell syntax that must remain inert.

A source-build checksum record proves that the shipped bytes agree with that build's inventory; it is not cryptographic attestation of an untrusted compiler. Release CI must build from the pinned sources in a clean environment, invoke this verifier before packaging, and publish the matching corresponding source archives and build records. The native DMG packager separately checks the assembled application's complete dependency graph and signature.
