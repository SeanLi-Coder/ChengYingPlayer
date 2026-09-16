# Local WebP image codec

This source-built, local-only helper links libwebp 1.6.0 statically. It has no
Homebrew runtime dependency, subprocess launcher, network client, or image parser.
The native application performs color-managed image decoding and supplies bounded
RGBA data. Application releases include this codec's matching source and notices.

## Build and test

```sh
bash other/build_image_codec.sh
bash Tools/ImageCodecHelper/run.sh
```

The build verifies the official source archive against the SHA-256 recorded in
`other/third_party_sources.sh`. `ARCHS=arm64` targets macOS 12; `ARCHS=x86_64`
targets macOS 10.15. Native ImageIO WebP playback additionally requires macOS 11.
The output is `deps/executable/chengying-image-codec`. Place it in the application's
`Contents/MacOS`, sign it as a nested executable, and install the retained libwebp
notices from `Legal/ThirdParty/libwebp` into `Contents/Resources/Legal/libwebp`.
Tagged source archives automatically include libwebp via the shared source list.

## Protocol version 1

```text
chengying-image-codec encode <absolute-manifest-path> <absolute-output-path>
```

The UTF-8/ASCII manifest contains only these lines (LF line endings):

```text
CHENGYING_WEBP_1
width height frame_count loop_count icc_byte_count
duration_ms_for_frame_0
duration_ms_for_frame_1
```

There must be exactly one duration line per frame, including the last frame.
Frames are regular, non-symlink files next to the manifest, named
`frame-000000.rgba`, `frame-000001.rgba`, and so on. Each contains exactly
`width * height * 4` bytes: RGBA8, straight/unpremultiplied alpha, top-to-bottom
rows, and no stride padding. When `icc_byte_count > 0`, the same directory must
contain exactly that many bytes in `profile.icc`. The helper embeds those bytes
unchanged and does not convert their color space. Omit the profile only for data
that is already in sRGB. A private per-job directory is required.

A static image has one frame and duration `0`. Animated frames have durations
from 1 to 16,777,215 milliseconds, with a summed duration no greater than
`INT_MAX`. Loop count is 0 for infinite repetition, otherwise 1 through 65,535.
Dimensions are 1 through 16,383. Each raw frame is limited to 256 MiB, the sum of
raw frame sizes to 8 GiB, frame count to 10,000, and the ICC profile to 4 MiB.
The accumulated compressed frames plus conservative container/ICC overhead are
limited to 512 MiB before copying each encoded frame into the mux. The assembled
file is checked against the same limit. This bounds stored compressed output;
the encoder also needs its current frame and internal working memory.
These are explicit safety limits, not resizing or frame-dropping instructions.

The encoder uses lossless mode, quality 100, method 6, and exact alpha. Each frame
is encoded independently, then added with `WebPMuxPushFrame` using a full canvas,
no blending, and no disposal. Unlike `WebPAnimEncoder`, this preserves even
consecutive identical frames and their individual durations. It does not reduce
dimensions, color depth, or frame timing beyond the caller's RGBA8/ms contract.
Converting a higher-bit-depth source to this contract requires a user-visible
precision warning from the caller.

Success prints `FRAME <completed> <total>` for each submitted frame, followed by
`DONE <encoded_byte_count>`. Failure prints a bounded English error on stderr and
returns 1; invalid invocation returns 2; cancellation returns 130. These records
are local progress, not an ETA. SIGTERM/SIGINT cancel encoding. The caller must
drain stdout and stderr, terminate/wait on cancellation, and remove its private
job directory afterward, including after a forced kill.

Output is written to a private temporary file next to the requested destination,
then atomically published using an exclusive hard link, or Darwin's exclusive
rename on filesystems such as exFAT that do not support hard links. Existing files
and symlinks are never replaced. The native caller should pass a path in its private
job directory, verify the result, and exclusively publish it to the chosen final
location. Failed encoding does not publish a partial output. Publication is the
commit point: a cancellation arriving afterward may leave a completed private
result, which the caller must discard after checking its cancellation token.
