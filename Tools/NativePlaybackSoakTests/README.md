# Native 4K displayed-buffer stress test

Run `bash Tools/NativePlaybackSoakTests/run.sh` on Apple Silicon macOS 14.4 or
newer with a WindowServer. `NATIVE_SOAK_SECONDS=60` selects the initial short run;
the default is 180 seconds, divided between three independent session lifetimes.
Minimum active-playback coverage can make a short run exceed its requested time.
The fixture/reference encoder remains the repository's FFmpeg executable.
Playback libraries default to `deps`; `NATIVE_PLAYBACK_DEPS` selects an existing,
independently built dependency tree without modifying the original `deps`:

```bash
NATIVE_PLAYBACK_DEPS="$PWD/build/native-av1-playback.7FMHum" \
  NATIVE_SOAK_SECONDS=180 bash Tools/NativePlaybackSoakTests/run.sh
```

The shared `Tools/RenderTestSupport/native_dependencies.sh` verifier checks all
published headers, all nine playback dylibs, their recorded checksums, install
names, rpaths, dynamic dependency closure, ARM64 slices and signatures before
compilation. A nonempty `DYLD_*` override is rejected. The selected root and
verified library identities are preserved in `dependency-root.txt` and
`dependency-runtime.json`; an AV1-capable library alone does not make this
H.264/HEVC test an AV1 hardware test.

The actual production pipeline executes without an app-service mock:

`4K H.264/AAC or HEVC Main10/AAC file -> CYNMediaDecoder -> NativePlaybackSession -> NativeSampleBufferOutput -> NativePlaybackSurface -> displayedPixelBuffer()`

This creates a transient CLI-owned 640x360 AppKit window. It does not install or
register an app, change the default playback route, open personal media, capture
the desktop, or initialize libmpv/OpenGL. All fixture audio samples are silent;
both production output volume and every session snapshot must remain zero.

## What is checked

- The decoded **displayed pixel buffer** must be 3840x2160, not merely a source
  header claiming 4K. H.264 remains 8-bit NV12; HEVC Main10 remains 10-bit P010.
- Independent FFmpeg decodes create reference YUV values for four two-second
  source intervals. Paused seeks in both directions compare nine displayed
  points to that reference, within one code value. The actual shared timebase
  must be stopped and within one millisecond of the requested position.
  Both audio and video accepted-sample counters must advance during each seek;
  this verifies refill, not audible output or sample-accurate A/V drift.
- Each session receives twelve rapidly superseding opens. The last 10-bit file
  must display without an earlier 8-bit buffer satisfying the check.
- Rate changes to 0.5x, 1x and 1.75x refill real audio/video queues. The actual
  timebase rate and advancement are observed, followed by a stable paused clock.
  Logs include displayed size/depth, clock/rate, and selected audio channels/rate.
- Stop clears displayed pixels, reopen works, repeated playback shows all four
  intervals, shutdown is asynchronous, and each retired session is deallocated.
- The application-reported outstanding sample budget remains at most 128 MiB.
  This budget is **not** all process memory: decoder, framework, IOSurface and
  render-server allocations have separate lifetimes.

Mach resident and physical-footprint memory are sampled, with a once-per-second
log of time, generation, revision, phase and outstanding sample bytes. The final
post-close samples report growth between the second and third rounds to make
repeated runs comparable; they do not establish a hard total-memory guarantee,
zero leaks, or superiority over another player. Renderer reads are observations,
not counts of unique presented frames. Image-less observations during sustained
playback (which includes loop flushes) are counted explicitly, not silently labeled
stutter-free or assigned a cause without a separate timing investigation.

`NATIVE_SOAK_WRONG_REFERENCE=1 NATIVE_SOAK_SECONDS=60 bash Tools/NativePlaybackSoakTests/run.sh`
is a negative control: it selects the wrong source interval only for the expected
pixels. Production playback is unchanged, and the first pixel check must fail
before completing a normal cleanup. Do not treat this expected failure as a pass
for the normal stress run.

The runner preserves synthetic media, independent references and `results.log`
under its printed `build/native-playback-soak.*` directory. All production/test
source inputs, the runner/verifiers and reference FFmpeg executable are hashed
before compilation and checked again on exit, including failure exits. Generated
objects/executable, fixtures and reference data are hashed before playback and
verified afterward; headers, the complete playback library closure and identity
records also have before/after manifests and validation logs. Source, generated
or dependency changes force failure even if the playback process returned zero.
Compiler/fixture logs and individual command/`tee` exit statuses are retained;
`results-exit-status.txt` is the actual timed playback command's status,
`identity-exit-status.txt` is the independent identity verdict, and
`exit-status.txt` is the combined runner result. The original external deadline
remains the requested duration plus 150 seconds; no assertion or wait was relaxed.
Only this run's compiled executable/object files are removed after validation.
No real user files are touched. Missing display capability is unverified (77);
the external deadline is a failing termination. Unknown negative-control values
are rejected rather than silently running the positive test.

## Boundaries

Uniform-color fixtures make exact pixel comparisons reproducible but do not
represent difficult film/grain, every codec/profile, or very long real-world files.
Hardware proof is reported only when the decoder's separate evidence flag says
so. In particular, HEVC's VideoToolbox path may allow software fallback, so a
VideoToolbox sample alone is not proof of hardware decoding. This test does not
certify M4 Max AV1, physical HDR/EDR, audible output or audio/video drift, complete
shipping-app interaction, or a default playback-engine migration. It is not added
as a slow CI gate by this change.

## Earlier local evidence (2026-10-13)

The following results predate the AV1 decoder/backport changes. They are retained
as historical evidence, not validation of the newer source or dependency tree.

On the development M2 Pro, the final 180-second run completed three independent
session lifetimes in 182.26 seconds: **292 checks, zero failures**. Each round
observed all four independently decoded reference intervals; invalid pixel
dimensions/formats and unknown colors were zero. There were 2, 0, and 2 image-less
observations during sustained playback, respectively. Their duration and exact
cause were not measured; this is not a stutter-free playback claim.

The wrong-reference control failed exactly one of 16 checks, the first displayed
pixel comparison, and then cleaned up normally. Its recorded production/test
source hashes match the successful run exactly. The first 60-second development
smoke run also passed before the stricter sustained-reference mapping was added;
it is not substituted for the final result.

Final evidence: `build/native-playback-soak.WbPdz3/results.log` and its
`source-sha256.txt`; negative evidence: `build/native-playback-soak.oQJFvE/`.
The highest published application sample budget was 124,623,360 bytes. Process
resident and physical-footprint peaks were 249,331,712 and 192,299,968 bytes;
these are measurements of this run, not resource requirements or upper bounds.
No production source or CI workflow was changed by this test suite.

## AV1-backport dependency regression (2026-10-13)

The updated runner was executed against the isolated, verified playback tree
`build/native-av1-playback.7FMHum`; it did not overwrite repository `deps` or
change production sources. The source snapshot is distinct from the earlier
evidence above:

- `CYNMediaDecoder.m`: `e3bcc18ecde84e48cf5556308eac7fc9802d6e5818ceecabe5b85e738b8958b9`
- `NativePlaybackSession.swift`: `5542c2670f188ff5c89a5d2d3f07b9937360057834db347ed7b765a32ddea3d1`
- Selected `libavcodec.61.dylib`: `a183c8200217cf86a17817d6049efeb3502102bb02756224994d5ed5dec62dcc`
- Test `main.swift` remained unchanged: `04c96343f654bfb8d84e3766e3b0f0e4f3fb1679b08d573515ee6d939d33e146`
- Updated runner: `4ee0aaadcc98c0f6beb5a4bb285d196ee0d74f71d47952e40ad662975d91bc3b`

The command above completed the original three-round 180-second scenario in
182.55 seconds: **292 checks, zero failures**, with playback, log capture,
identity validation and combined runner status all zero. Evidence is preserved
at `build/native-playback-soak.iX9p53/`. All 14 source/tool inputs, 156 dependency
entries and six generated products passed final validation. Source and generated
before/after manifests match, as does the complete dependency inventory.

All rounds displayed the four independently decoded source intervals; invalid
dimensions/formats and unknown colors remained zero. Sustained playback counted
4, 6 and 3 image-less observations. These are retained observations, not a
stutter-free claim or a diagnosis of their duration/cause. Peak application
sample budget was 124,623,360 bytes; process RSS and physical-footprint peaks
were 260,276,224 and 166,462,400 bytes. Post-close growth from round two to round
three was -573,440 bytes RSS and -40,615,960 bytes physical footprint; neither a
negative delta nor a short run proves the absence of leaks.

The exact existing wrong-reference control was rerun with the same production,
test and dependency hashes:

```bash
NATIVE_PLAYBACK_DEPS="$PWD/build/native-av1-playback.7FMHum" \
  NATIVE_SOAK_WRONG_REFERENCE=1 NATIVE_SOAK_SECONDS=60 \
  bash Tools/NativePlaybackSoakTests/run.sh
```

It produced **16 checks, one expected failure**, precisely the first displayed
pixel comparison at H.264 position 0.25. Asynchronous shutdown, layer clearing,
silent output and weak-session release checks then passed. The actual playback
and combined runner exits were 1, while log capture and all identity checks
exited zero. Evidence is `build/native-playback-soak.DOJ5cD/`; it is not counted
as a successful soak. An invalid control value was separately rejected with
exit 2 before compilation (`build/native-playback-soak.PIGFZ8/`).

This validates the newer libraries for this actual H.264/HEVC decoder-to-display
chain on the development M2 Pro. It does not exercise AV1, the complete
ChengYing App/nib, physical HDR, audible sound, measured A/V drift, or target M4
hardware. The original default backend, assertions and deadlines are unchanged.

## EOF-rate-fix regression (2026-10-13)

After `NativePlaybackSession.swift` changed to `aab38cba18651a86e7250e743a9af2e580ae50c67c3bc7ee150f937d6184d1af`,
the same 180-second command and isolated `7FMHum` dependency tree were run again.
The actual three-lifetime run completed **292 checks, zero failures** in 182.22
seconds, evidence `build/native-playback-soak.85CsqG/`. Compilation, playback,
log capture, source/generated/dependency identities and combined runner status
were all zero. The unchanged wrong-reference control in
`build/native-playback-soak.tYX5s4/` produced exactly **16 checks, one failure** at
the first H.264 pixel comparison; playback and runner exited 1, identity and log
capture exited zero, and asynchronous cleanup completed. Both runs have identical
source and dependency manifests; generated before/after manifests also match.

Each sustained round observed all four source intervals with no invalid dimensions,
formats or unknown colors. Image-less observations were 4, 2 and 5; their duration
and cause were not measured. Peak application sample budget was 124,623,360 bytes;
RSS and physical-footprint peaks were 261,242,880 and 180,208,624 bytes. Post-close
round-two-to-three changes were +4,472,832 and -42,270,744 bytes respectively.
All three retired sessions were deallocated. This remains a short synthetic,
silent H.264/HEVC displayed-buffer test, not a zero-leak/stutter-free guarantee,
AV1 hardware test, physical HDR/audio verification or full application acceptance.
