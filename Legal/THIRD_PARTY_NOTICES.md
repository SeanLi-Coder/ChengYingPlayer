# Third-party notices for bundled video tools

A ChengYingPlayer application contains separate `ffmpeg`, `ffprobe`, `chengying-video-tools-helper`, and `chengying-subtitle-tools-helper` executables. Exact media-tool source inputs and matching source distributions for the helper toolchain are fixed in [`other/third_party_sources.sh`](../other/third_party_sources.sh); exact Python build-wheel versions and hashes are fixed in [`Tools/VideoToolsHelper/requirements-build.txt`](../Tools/VideoToolsHelper/requirements-build.txt). Local and CI builds verify the applicable downloads by SHA-256. Application releases include a matching source archive and the notices described below.

## Source-built playback stack and Swift packages

The Apple Silicon playback build uses libmpv 0.38.0 and FFmpeg 7.1.5, preserving the public libmpv 2 / FFmpeg 61 ABI. dav1d 1.5.3, libplacebo 6.338.2, Little CMS 2.16, zimg 3.0.5, uchardet 0.0.8, fast_float and the five subtitle libraries listed below are built from verified source and linked statically where applicable. Jinja, MarkupSafe and Vulkan-Headers are fixed build inputs for libplacebo; they do not add a Python or Vulkan runtime requirement to the player. The exact commits, archive hashes and source URLs are in [`other/playback_sources.sh`](../other/playback_sources.sh).

The mpv source is modified by ChengYingPlayer maintainers on 2026-09-17 and 2026-09-21 with three explicit patches: upstream commit `6f619d5ef43b070d728e43f0b2fe0571449de1a8` is backported to fix public ICC-buffer ownership, a project patch synchronizes renderer options before applying an ICC profile, and upstream commit `d59f4fd3ec141693da4f7f6677aa729e1bb92f4d` is backported in full to preserve end-of-file teardown state when a seek is queued. Their provenance, ordered manifest, exact patch bytes and original/modified source hashes are in [`other/patches`](../other/patches/README.md). The application Legal/Playback directory and matching release source archive retain these patches, hashes and modified source copies from the actual build. Original upstream notices remain unchanged; these modifications do not change the public libmpv ABI version.

mpv's GPLv2-or-later terms, FFmpeg's GPLv3-or-later configuration, uchardet's MPL/GPL/LGPL alternatives and the other components' distinct license texts are preserved from the verified source archives under `Contents/Resources/Legal/Playback/licenses`. FreeType, HarfBuzz, FriBidi, libunibreak and libass notices are also reproduced separately. The application as a whole remains GPLv3; this does not relabel every dependency as GPLv3. The same source archives, actual build configuration and scripts accompany the release. Libraries extracted from another application's DMG are not accepted as release inputs.

Just, PromiseKit and GRMustache are resolved to the exact commits in the Xcode project; Sparkle 2.7.0's package revision fixes its binary URL and SHA-256 checksum. The matching four source archives are pinned in `other/third_party_sources.sh`. Their original license files, including Sparkle's embedded third-party notices, are reproduced in the main Legal directory. Their optional test/extension submodules are not linked by this project's Swift package targets.

## FFmpeg video tools

The bundled `ffmpeg` and `ffprobe` executables are built from the following source code:

| Component | Exact version | License used by this build | Source |
| --- | --- | --- | --- |
| FFmpeg | 9.0.1 | GPLv3-or-later build (`--enable-gpl --enable-version3`) | <https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz> |
| x264 | r3222, commit `b35605ace3ddf7c1a5d67a2eb553f034aef41d55` | GPLv2-or-later | <https://code.videolan.org/videolan/x264/-/tree/b35605ace3ddf7c1a5d67a2eb553f034aef41d55> |
| x265 | 4.3 | GPLv2-or-later | <https://github.com/Multicorewareinc/x265/releases/tag/4.3> |
| FreeType | 2.14.3 | FreeType License (FTL); GPLv2 alternative also reproduced | <https://freetype.org/> |
| HarfBuzz | 14.4.0 | MIT-style notices in `COPYING` | <https://github.com/harfbuzz/harfbuzz/releases/tag/14.4.0> |
| FriBidi | 1.0.16 | LGPLv2.1-or-later | <https://github.com/fribidi/fribidi/releases/tag/v1.0.16> |
| libunibreak | 8.0 | zlib-style license | <https://github.com/adah1972/libunibreak/releases/tag/libunibreak_8_0> |
| libass | 0.17.5 | ISC | <https://github.com/libass/libass/releases/tag/0.17.5> |

x264 and x265 are statically linked into the FFmpeg executables. Because both codec libraries allow use under later GPL versions and this FFmpeg configuration enables GPLv3 components, those executables are conveyed under GPLv3-or-later. The application as a whole remains GPLv3 under the repository [`LICENSE`](../LICENSE).

A built application includes the applicable FFmpeg, x264, and x265 license texts in `Contents/Resources/Legal`. The matching release source asset includes the exact verified source archives and build scripts used to recreate these executables.

Subtitle rendering additionally links the five font/shaping libraries above statically, using macOS CoreText for font discovery instead of an external Fontconfig installation. Their notices are also installed in `Contents/Resources/Legal`, and their pinned source archives are included with tagged source releases. Portions of this software are copyright © The FreeType Project (<https://freetype.org/>). All rights reserved.

## Frozen local helper

Both local helper executables contain the project's Python source plus a frozen Python runtime produced with:

| Component | Exact version | License | Source |
| --- | --- | --- | --- |
| CPython | 3.13.2 | Python Software Foundation License Version 2 and the historical licenses reproduced in CPython's `LICENSE` | <https://www.python.org/downloads/release/python-3132/> |
| PyInstaller | 6.22.2 | GPLv2-or-later with the PyInstaller Bootloader Exception; embedded runtime hooks may use Apache-2.0 | <https://pypi.org/project/pyinstaller/6.22.2/> |

The PyInstaller Bootloader Exception permits the compiled bootloader and related files to be embedded in and distributed with the application without imposing additional restrictions on the combined executable. The helper's own source remains part of this GPLv3 project.

The PyInstaller build environment also pins `altgraph` 0.17.5 (MIT), `macholib` 1.16.4 (MIT), `packaging` 26.3 (Apache-2.0 OR BSD-2-Clause), `pyinstaller-hooks-contrib` 2026.7 (Apache-2.0 and GPLv2 notices), and `setuptools` 84.0.0 (MIT). These packages are build tools rather than application features; their versions and wheel hashes are fixed in [`Tools/VideoToolsHelper/requirements-build.txt`](../Tools/VideoToolsHelper/requirements-build.txt).

A built application reproduces the complete CPython and PyInstaller license files, the notices for PyInstaller's embedded `waflib` and `zlib` bootloader components, and the primary notices for every pinned helper build dependency in `Contents/Resources/Legal`. The release source archive includes the exact source distributions used by the source build process.

## Optional, separately downloaded subtitle assets

The subtitle supervisor contains no neural-network weights or PyTorch runtime. At the user's request it downloads fixed official artifacts identified by immutable revisions, exact lengths, and SHA-256 hashes in [`Tools/SubtitleToolsHelper/assets.json`](../Tools/SubtitleToolsHelper/assets.json). These assets are not included in the repository or its source releases, and their upstream licenses apply independently of this application's GPLv3 source license.

| Model | Official repository | License |
| --- | --- | --- |
| Qwen3-ASR 1.7B (full BF16) | <https://huggingface.co/Qwen/Qwen3-ASR-1.7B-hf> | Apache-2.0 |
| Qwen3-ForcedAligner 0.6B (full BF16) | <https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B-hf> | Apache-2.0 |
| Hy-MT2 30B-A3B (full BF16) | <https://huggingface.co/tencent/Hy-MT2-30B-A3B> | Tencent HY Community License, **not Apache-2.0**; see the repository's license and applicable use restrictions |

The optional isolated runtime uses Astral's CPython 3.13.15 standalone build and pinned PyPI wheels. Model license files are downloaded where provided in the official snapshots; runtime package notices remain in their installed distributions. The lock records the reviewed model licenses and links, including Qwen's Apache-2.0 notice, and the model manager links to those licenses before download. Redistribution of these external assets requires a separate review of their actual license terms and corresponding-source obligations; their availability for download is not a blanket redistribution permission. Runtime installation occurs offline from the verified wheelhouse, and inference uses only local model files without remote Python code.

Subtitle segmentation and translation handling adapt the repository owner's earlier [subtitle_add / 译幕](https://github.com/SeanLi-Coder/subtitle_add) workflow. The new native interface, resumable asset manager, isolated runtime, and local worker are distributed as source under this project's GPLv3 license.

## Download center

The downloader engine and its original interface retain the MIT license of Original Media Downloader / 原迹下载器, copyright © 2026 Sean Li. The vendored version is 1.2.23 at commit `e532e4fcd74bce4dfe730e49b8f1b49adceff62e`; see [`Tools/DownloaderHelper/UPSTREAM.md`](../Tools/DownloaderHelper/UPSTREAM.md), its retained `vendor/rednote/LICENSE`, and the per-file SHA-256 manifest. Native-host modifications are part of this GPLv3 project.

The native background helper application embeds the same pinned CPython/PyInstaller toolchain and fixed runtime wheels. It uses PyInstaller's macOS BUNDLE layout to separate executable code from sealed resources. Exact package versions, wheel URLs and SHA-256 digests are fixed in [`Tools/DownloaderHelper/runtime-artifacts.json`](../Tools/DownloaderHelper/runtime-artifacts.json). This includes yt-dlp 2026.8.19, its EJS solver, and Playwright 1.62.0 with Node 24.18.1. The native adapter reuses that Node executable for EJS and does not distribute Deno. License files and bundled third-party notices preserve each component's distinct terms; they are not all described as GPLv3 or MIT.

The local application build stores these notices in the helper's `Contents/Resources/Legal` and in the player's `Contents/Resources/Legal/DownloadCenter`. The Google Chrome browser is not included; users supply their own installation. No browser profile, Cookie store, download history, or downloaded media is included in the repository or build inputs.

[`Tools/DownloaderHelper/runtime-sources.json`](../Tools/DownloaderHelper/runtime-sources.json) and `rust-sources.json` identify corresponding verified source materials, including Mutagen (GPLv2-or-later), Certifi (MPLv2), Node, OpenSSL and conservative Cargo.lock dependency supersets. Superset entries are not claims that every target or test dependency is linked. The source archives and their original notices accompany the distribution; the frozen build rejects unpinned development packages. CPython's complete `Doc/license.rst` is also retained as `CPython-THIRD-PARTY-NOTICES.rst`. See [`Tools/DownloaderHelper/DISTRIBUTION.md`](../Tools/DownloaderHelper/DISTRIBUTION.md) for exact collection and runtime details.

## Native image viewer and WebP encoding

The native image interface and ImageIO/Core Image/PDFKit integration are new project code. FlowVision, qView, Phoenix Slides, iMonet, and SDWebImage were evaluated as references; their implementation code is not copied or linked into this module. In particular, no Phoenix Slides code under its noncommercial license or retired FFmpegKit binaries are included.

`chengying-image-codec` statically links libwebp **1.6.0**, including its SharpYUV component, built from the SHA-256-verified official source archive pinned in `other/third_party_sources.sh`. The upstream BSD-style `COPYING`, patent grant `PATENTS`, and `AUTHORS` are retained in the application's `Legal/libwebp` directory and the verified source archive accompanies tagged source releases. See [`Tools/ImageCodecHelper/README.md`](../Tools/ImageCodecHelper/README.md) and [`Legal/ThirdParty/libwebp/README.md`](ThirdParty/libwebp/README.md).

## Integrity and source availability

The authoritative checksums, filenames, and download URLs are stored in [`other/third_party_sources.sh`](../other/third_party_sources.sh) and reproduced as `SOURCE_MANIFEST.txt` in both a locally built application bundle and the release source archive. The build fails if a downloaded archive does not match its recorded SHA-256.

For each tagged application release, the same GitHub Release provides an Apple Silicon DMG, a matching `Release-Source.tar.gz`, both SHA-256 checksums, and a third-party source manifest. The source archive contains the exact tagged project tree, the playback build's configuration and checksums, and verified source materials for playback, Swift packages, video tools and helpers.

Publication must fail if source provenance, the bundled notices, dependency closure or application verification is incomplete. A rebuilt dependency or changed build option requires its own matching records and notices; an old successful build is not evidence for a changed binary. Anyone independently distributing an application binary is responsible for meeting GPLv3 and all applicable third-party license requirements for the exact binaries they distribute.
