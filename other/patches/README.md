# Playback source modifications

The checksum-pinned mpv 0.38.0 archive remains unmodified in the source cache.
`other/playback_patches.sh` applies the following patches in the exact order in
`playback-patches.tsv` before compilation, with no fuzz and with checksums of
every affected source file both before and after patching.

Modified by ChengYingPlayer maintainers on 2026-09-17:

1. `mpv-0.38.0-icc-profile-ownership.patch` backports the complete upstream fix
   [6f619d5ef43b070d728e43f0b2fe0571449de1a8](https://github.com/mpv-player/mpv/commit/6f619d5ef43b070d728e43f0b2fe0571449de1a8)
   from 2024-08-06. Only documentation hunk context is adapted to the release
   archive. It copies caller-owned ICC bytes into mpv's allocator before internal
   ownership transfer, and removes the redundant copy in mpv's own macOS client.
   It does not change the advertised libmpv ABI version.
2. `mpv-0.38.0-icc-option-refresh.patch` is a project modification. It refreshes
   the renderer's option cache before submitting a display profile, so setting
   `icc-profile-auto=yes` followed immediately by the public ICC render API does
   not silently discard the profile. It retains the original disabled-auto and
   explicit-profile precedence behavior. This executes on the same locked GL
   render context as the existing render API; it does not wait on the player core.

These modifications retain mpv's applicable license terms. Original upstream
notices are preserved byte-for-byte separately, not rewritten to imply that the
patches were part of the original release.

The source archive includes this directory and the build/apply scripts. The same
build's `playback-build-record` contains the exact patch bytes and ordered
manifest, original/patched file hashes, and complete copies of the modified
source files. Distribution verification rejects missing, extra, linked, reordered
or modified patches and mismatched source-file hashes. `Tools/ICCProfileTests`
exercises caller-owned buffer lifetime and real managed-color pixels; the App
smoke test covers the production Swift integration.
