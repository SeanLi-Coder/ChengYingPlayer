# Synthetic Dolby Vision metadata

`metadata.json` contains gzip/base64-encoded synthetic RPU sequences, not footage.
Each profile has 90 frames with different Level 1 luminance statistics, Level 2 trim
slope, Level 5 active-area offsets and Level 8 trims on every frame. Static mastering
values are intentionally artificial and are not suitable for grading actual media.

`generate.py` constructs the configuration and uses the upstream MIT-licensed
[dovi_tool 2.3.4](https://github.com/quietvoid/dovi_tool/tree/2.3.4) generator to emit
the RPU bytes. The upstream authors retain ownership of their tool; no executable or
source from that tool is bundled here or required by the app/tests. Generator format:
[upstream documentation](https://github.com/quietvoid/dovi_tool/blob/2.3.4/docs/generator.md).

To reproduce the metadata, run `python generate.py /absolute/path/dovi_tool` and
compare the emitted JSON and SHA-256 values with `metadata.json`. The generator
does not use network access, accounts, real footage, or private user files.

`../../dovi_fixtures.py` generates `testsrc2` video and a synthetic 48 kHz stereo
tone with the bundled FFmpeg. It inserts these synthetic RPUs into a no-B-frame
elementary test stream, then creates a real long-GOP/B-frame MP4 with correct Dolby
Vision container signaling. The optional VFR variant varies frame timestamps.
Runtime test dependencies are Python's standard library and bundled FFmpeg only.

The complete RPU checks use FFmpeg's `dovi_rpu=compression=none` plus
`filter_units=pass_types=62` and `framehash`; optional development-only validation
with `dovi_tool extract-rpu` and `export` independently compares the full metadata
structure, including all extension blocks. The production code does not rely on
FFprobe's partial readable RPU fields as proof of extension-block preservation.
