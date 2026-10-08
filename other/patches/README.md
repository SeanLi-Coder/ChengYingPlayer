# Playback source modifications

The checksum-pinned mpv 0.38.0 archive remains unmodified in the source cache.
`other/playback_patches.sh` applies the following patches in the exact order in
`playback-patches.tsv` before compilation, with no fuzz and with checksums of
every affected source file both before and after patching.

Modified by ChengYingPlayer maintainers on 2026-09-17, 2026-09-21, 2026-09-28
and 2026-10-09:

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
3. `mpv-0.38.0-unload-seek-state.patch` backports the complete upstream fix
   [d59f4fd3ec141693da4f7f6677aa729e1bb92f4d](https://github.com/mpv-player/mpv/commit/d59f4fd3ec141693da4f7f6677aa729e1bb92f4d)
   from 2024-05-16 for [mpv issue #13778](https://github.com/mpv-player/mpv/issues/13778).
   It preserves the end-of-file stop reason when queueing a seek and removes
   the matching play-direction workaround. Only hunk line numbers are adapted
   to the release archive. This prevents an `on_unload` hook's video-rotation
   refresh from invalidating playback teardown state; a successfully executed
   seek still clears end-of-file normally. The teardown assertion remains intact.
4. `mpv-0.38.0-dovi-base-layer-colors.patch` backports upstream's Dolby Vision
   base-layer fallback for renderers without Dolby Vision reshaping. The shared
   OpenGL initialization follows
   [c02aa154ab45d3534e2c507f5f7a7e1b1c4e81f2](https://github.com/mpv-player/mpv/commit/c02aa154ab45d3534e2c507f5f7a7e1b1c4e81f2),
   which consolidated the earlier vo_gpu and embedded libmpv fixes. The complete
   dependency commits are identified in the patch header: original color tags
   are retained through attribute copies and AVFrame round-trips, and explicit
   `format:dolbyvision=no` restores the base-layer tags before applying overrides.
   The gamma-change check also includes the upstream fix
   [c9cf510d6aab4409273278e33280fb5893640301](https://github.com/mpv-player/mpv/commit/c9cf510d6aab4409273278e33280fb5893640301).

   The pinned mpv 0.38.0 decoder infers PQ display light and Dolby Vision peaks
   before GL setup. This project adaptation also saves and restores the original
   HDR metadata and light model, clears the unused mapping pointer, and detects
   changes in original color tags and static HDR mastering metadata during
   renderer reconfiguration, while ignoring per-frame metadata changes. This lets
   HLG-compatible Dolby Vision use the HLG base layer instead of interpreting
   its pixel values as PQ. Plain SDR, HDR10/PQ and HLG keep their original path.
   Dolby Vision side data remains available to capable renderers and FFmpeg;
   this is not Dolby Vision reshaping support for embedded OpenGL. No public
   libmpv header, library version, or dependency ABI is changed.
5. `mpv-0.38.0-scaler-lut-padding.patch` backports the complete upstream fix
   [72d43dc9c999a21d867cdc0f934f3e4cd2195aa9](https://github.com/mpv-player/mpv/commit/72d43dc9c999a21d867cdc0f934f3e4cd2195aa9)
   from 2026-09-29 for [mpv PR #18540](https://github.com/mpv-player/mpv/pull/18540).
   The six-tap scaler allocates two RGBA texels per LUT row but previously left
   two components uninitialized. The patch fills those components from the same
   channels of the preceding texel before upload. Computed coefficients, filter
   selection, image quality settings and public ABI remain unchanged. Only hunk
   line numbers and trailing context are adapted to the patched 0.38.0 source.

   `python3 -B other/patches/test_scaler_lut.py` verifies the complete ordered
   patch chain in an isolated source tree and compiles the actual pinned filter
   kernels plus the extracted padding block with ASan/UBSan. It reproduces the
   unfixed six-tap poison case and checks all built-in kernels, supported filter
   sizes, polar filters, padding and unchanged valid coefficients. This is a
   source-level regression, not a substitute for real GPU playback validation.

These modifications retain mpv's applicable license terms. Original upstream
notices are preserved byte-for-byte separately, not rewritten to imply that the
patches were part of the original release.

The source archive includes this directory and the build/apply scripts. The same
build's `playback-build-record` contains the exact patch bytes and ordered
manifest, original/patched file hashes, and complete copies of the modified
source files. Distribution verification rejects missing, extra, linked, reordered
or modified patches and mismatched source-file hashes. `Tools/ICCProfileTests`
exercises caller-owned buffer lifetime and real managed-color pixels; the App
smoke test covers the production Swift integration. `Tools/PlaybackRotationTests`
reproduces the original end-of-file rotation failure and checks patched playback
teardown, repeated rotation, and seek behavior.
`Tools/HDRSourceTests` compiles actual image and format-filter functions with
the pinned libplacebo and bundled FFmpeg, reproduces the unpatched HLG failure,
then checks synthetic Dolby Vision/HLG, PQ and SDR metadata through fallback,
attribute copies, and AVFrame round-trips under ASan/UBSan.

## FFmpeg media-tool modifications

On 2026-10-05 ChengYingPlayer maintainers modified the verified FFmpeg 9.0.1
source in `ffmpeg-9.0.1-hdr10plus.patch`. Its libx265 option `-hdr10plus 1`
requires HDR10+ metadata on every input frame and passes the complete Samsung
ITU-T T.35 payload to x265's copied per-frame SEI, preserving frame association
through delayed and B-frame output. The option defaults to disabled. The patch
also corrects HDR10+ color-saturation serialization when tone mapping is absent.
The serializer follows FFmpeg's existing libaom implementation; FFmpeg's
LGPL-2.1-or-later source notices and the distribution's GPLv3 configuration remain.

`other/media_patches.sh` uses the independent `media-patches.tsv`,
`media-before-sha256.txt` and `media-after-sha256.txt` locks. It verifies the
original sources and patch bytes, applies with zero fuzz, verifies the modified
sources and records the exact modified files. `other/verify_media_distribution.py`
checks these records against the original verified archives and built executables.
The application carries the records in `Legal/Media`; release sources retain them
in `media-build-record`. `Tools/HDR10PlusCodecTests` exercises the production
codec using generated per-frame payloads, B frames, delayed flushing, missing
metadata rejection, optional tone-mapping/saturation syntax and other SEI data.
