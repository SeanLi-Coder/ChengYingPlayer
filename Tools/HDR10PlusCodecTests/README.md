# HDR10+ production codec regressions

Build the locked media executables with `bash other/build_media_binaries.sh`, then run:

```bash
python3 -B Tools/HDR10PlusCodecTests/test_distribution.py
python3 -B Tools/HDR10PlusCodecTests/test_codec.py
python3 -B other/verify_media_distribution.py deps
```

The codec test fails if the explicit `libx265 -hdr10plus` option is missing.
`CHENGYING_FFMPEG` and `CHENGYING_FFPROBE` can select exact packaged executables.
Tests generate 18 different HDR10+ T.35 payloads, independently of FFmpeg's
serializer, and insert them into a generated 10-bit BT.2020/PQ HEVC stream.
No private media or downloaded fixtures are used. Temporary data is automatically
removed; these tests do not create or execute application bundles.

The actual production decoder/encoder round-trip must retain every payload byte
and matching custom unregistered SEI, in presentation order, through B-frame
reordering and delayed flushing. Payloads cover one, two and three windows,
peak-luminance matrices, distribution percentiles, tone-mapping curves and color
saturation with and without tone mapping. The decoded frames retain the original
10-bit BT.2020/PQ limited-range tags. Missing metadata in the first or middle frame
and unsupported application versions must fail. The disabled option keeps its
existing behavior.

Distribution tests apply the locked patch to source files extracted from the
SHA-256-pinned FFmpeg archive and verify before/after hashes. Tampered or missing
patches, extra patch files, linked or changed sources and altered manifests fail.
The separate distribution verifier checks the complete source inputs, compiler
configuration, patch record and pre-application-signing FFmpeg/FFprobe hashes.
