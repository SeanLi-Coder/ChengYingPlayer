# Native 4K displayed-buffer stress test

Run `bash Tools/NativePlaybackSoakTests/run.sh` on Apple Silicon macOS 14.4 or
newer with a WindowServer. `NATIVE_SOAK_SECONDS=60` selects the initial short run;
the default is 180 seconds, divided between three independent session lifetimes.
Minimum active-playback coverage can make a short run exceed its requested time.
The runner uses the repository's FFmpeg executable and dynamic libraries.

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

The runner preserves synthetic media, independent references, source SHA-256
identities (verified unchanged across compilation), and `results.log`
under its printed `build/native-playback-soak.*` directory, removing only its
compiled executable/object files. No real user files are touched. Missing display
capability is unverified (77); the external deadline is a failing termination.

## Boundaries

Uniform-color fixtures make exact pixel comparisons reproducible but do not
represent difficult film/grain, every codec/profile, or very long real-world files.
Hardware proof is reported only when the decoder's separate evidence flag says
so. In particular, HEVC's VideoToolbox path may allow software fallback, so a
VideoToolbox sample alone is not proof of hardware decoding. This test does not
certify M4 Max AV1, physical HDR/EDR, audible output or audio/video drift, complete
shipping-app interaction, or a default playback-engine migration. It is not added
as a slow CI gate by this change.

## Local evidence (2026-10-13)

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
