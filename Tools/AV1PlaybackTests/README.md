# AV1 playback regression tests

Run `bash Tools/AV1PlaybackTests/run.sh /absolute/path/to/candidate-deps`.
The default dependency directory is the repository's `deps`. This suite requires
the AV1 VideoToolbox backport and verifies the actual dylib build-record hashes.
It creates no application bundle or visible window and reads no user media,
preferences, browser data, or network resources. Each compiler and executable has
an external timeout; generated files are confined to an owned temporary directory.

Coverage:

- Apply the exact SHA-locked backport with zero fuzz to verified FFmpeg 7.1.5
  originals. Reject preexisting empty files, dangling or regular symlinks, and
  malformed or broadened new-source markers before changing any source file.
- The native FFmpeg AV1 decoder advertises a VideoToolbox hardware configuration.
- The production Swift backend-capability helper compiles and returns true against
  the actual libraries; the whitelist retains a separate hardware-capability gate.
- The statically linked dav1d decoder decodes all 24 frames of both 8-bit and
  10-bit fixtures, preserving 192x108 display dimensions and the source bit depth.
- Actual libmpv loads each fixture in software and `videotoolbox-copy` modes,
  performs four exact seeks, plays to EOF, and tears down without a hang.
- A host without AV1 hardware must select software fallback in both modes.
  A hardware-capable host must actually select `videotoolbox-copy` in that mode.

This is a headless decoder test, not a display, HDR, ICC, GPU rendering, or 4K soak
test. In particular, an M2 software-fallback pass is not evidence of M4 AV1 hardware
decoding. Keep the existing render and soak suites as independent release gates.

The verified original `ffmpeg-7.1.5.tar.xz` is read from `SOURCE_CACHE_DIR` or
`deps/sources`; the suite does not fetch dependencies. To additionally prove that
the production Swift gate rejects an actual unpatched baseline, set
`AV1_BASELINE_DEPS=/absolute/path/to/old-deps`. Do not point that optional negative
control at already-patched libraries.

## Synthetic fixtures

The base64 files contain only FFmpeg's generated `testsrc2` pattern, not third-party
video. Both have 24 frames at 12 fps. They were generated with FFmpeg 9.0.2 and
SVT-AV1 4.2.0 (the encoder normalizes preset 13 to preset 11):

```sh
ffmpeg -hide_banner -loglevel error -nostdin \
  -f lavfi -i 'testsrc2=size=192x108:rate=12' -frames:v 24 -an \
  -c:v libsvtav1 -preset 13 -crf 35 -svtav1-params 'lp=2' \
  -pix_fmt yuv420p -f ivf av1-8bit.ivf
```

The 10-bit fixture uses `-pix_fmt yuv420p10le`. `run.py` pins the SHA-256 of
each decoded IVF file before execution. A system AV1 encoder is not needed to run
the tests. The playback backend stays pinned to the project's own FFmpeg 7.1.5
and dav1d sources; the external encoder was used solely to create test data.

## Independent VideoToolbox failure diagnostics

This additional matrix does not replace `run.py`, change its fixtures, or waive
any release assertion. Run it on the same machine that failed the strict suite:

```sh
python3 Tools/AV1PlaybackTests/diagnose.py \
  --deps "$PWD/deps" \
  --report "$PWD/build/av1-diagnostic-matrix" \
  --source-cache "$PWD/deps/sources"
```

The report directory must not already exist. All case logs and `summary.json`
remain there, including failed cases. The script verifies candidate-library and
fixture hashes, compiles the existing strict C test with only its expected image
dimensions adapted for the extra size, and tests each size/bit-depth combination
in an independent process. A failed 8-bit case therefore does not suppress the
10-bit or other-backend evidence. The original strict test file is not modified.

The independent reference is official, unpatched FFmpeg 9.0.1 from the existing
source lock and checksum-verifying fetch helper. Only a minimal native AV1 /
VideoToolbox / IVF / null-output CLI is built, not the project media helpers or
playback libraries. It has no dav1d or libaom fallback and no network protocol.
The reference requests VideoToolbox frames and explicitly downloads them through
`hwdownload`; a software-decoding fallback cannot pass that output chain. Each
reference case must exit successfully and report all 24 frames. Its source hash,
configuration, CLI checksum, version, and a null-output positive control are
included in the report. Source retrieval may contact the pinned official source
URL; no media, application binaries, or account data is uploaded.

The optional standalone builder accepts:

```sh
bash Tools/AV1PlaybackTests/build_reference.sh \
  --output /absolute/new/reference-directory \
  --source-cache "$PWD/deps/sources"
```

It produces `bin/ffmpeg` under that new directory and preserves build diagnostics
on failure; it refuses to overwrite any existing output. Prefer `diagnose.py`
for automatic process-group deadlines and cleanup. The builder has a 360-second
outer deadline in that runner, candidate cases have 60 seconds, reference cases
40 seconds, and the entire matrix has a 660-second deadline. A timed-out owned
process group is terminated and reaped. No application bundle, visible window,
user media, player preferences, or browser data is used.

`diagnostic-fixtures/` adds generated 1920x1080 8-bit and 10-bit patterns using the
same encoder command above with only `testsrc2` dimensions changed. The resulting
sequence headers also differ: small fixtures have AV1 level index 0, while the
1080p fixtures have level index 8. Therefore this is a format comparison, **not**
a proof that dimensions alone caused a VideoToolbox failure. Both sets remain
24 frames at 12 fps; `diagnose.py` pins each binary SHA-256. A successful larger
fixture never makes a failed original small-fixture release gate pass.

The matrix exits nonzero if any required setup or decoder case fails. In
particular, an M2 can pass the candidate software-fallback checks but must fail
the mandatory upstream forced-hardware cases; that is a useful negative control,
not a successful hardware validation. Identical failures in the candidate and
reference narrow the investigation but do not alone establish a virtual-machine,
OS, driver, or hardware root cause. If the reference succeeds where the candidate
fails, investigate the backport/integration before attributing it to the host.
