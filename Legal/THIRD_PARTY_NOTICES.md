# Third-party notices for bundled video tools

A locally built ChengYingPlayer application contains separate `ffmpeg`, `ffprobe`, `chengying-video-tools-helper`, and `chengying-subtitle-tools-helper` executables. Exact media-tool source inputs and matching source distributions for the helper toolchain are fixed in [`other/third_party_sources.sh`](../other/third_party_sources.sh); exact Python build-wheel versions and hashes are fixed in [`Tools/VideoToolsHelper/requirements-build.txt`](../Tools/VideoToolsHelper/requirements-build.txt). Local and CI builds verify the applicable downloads by SHA-256. The project currently publishes source-only releases and does not distribute these executables.

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

A built application includes the applicable FFmpeg, x264, and x265 license texts in `Contents/Resources/Legal`. The source-only release includes the exact verified source archives and build scripts used to recreate these added executables.

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

The native background helper application embeds the same pinned CPython/PyInstaller toolchain and fixed runtime wheels. It uses PyInstaller's macOS BUNDLE layout to separate executable code from sealed resources. The authoritative complete list of exact package versions, wheel URLs, and SHA-256 digests is [`Tools/DownloaderHelper/runtime-artifacts.json`](../Tools/DownloaderHelper/runtime-artifacts.json); the install locks reject artifacts with different hashes. This includes yt-dlp 2026.8.19, its EJS solver, Playwright 1.62.0 with its Node driver, and Deno 2.9.5. The build collects the installed distributions' license files and Playwright's bundled third-party notices, preserving their distinct terms; it does not represent every component as GPLv3 or MIT.

The local application build stores these notices in the helper's `Contents/Resources/Legal` and in the player's `Contents/Resources/Legal/DownloadCenter`. The Google Chrome browser is not included; users supply their own installation. No browser profile, Cookie store, download history, or downloaded media is included in the repository or build inputs.

See [`Tools/DownloaderHelper/DISTRIBUTION.md`](../Tools/DownloaderHelper/DISTRIBUTION.md) for limitations on redistribution. A source release includes the downloader source and dependency lock/manifest, not its runtime wheels or executables. Before anyone distributes a binary, all embedded runtime components, including nested Node/Deno dependencies, require the applicable notices and any corresponding-source obligations to be fulfilled for the exact distributed artifacts. The existing source-only release gate remains in force.

## Integrity and source availability

The authoritative checksums, filenames, and download URLs are stored in [`other/third_party_sources.sh`](../other/third_party_sources.sh) and reproduced as `SOURCE_MANIFEST.txt` in both a locally built application bundle and the release source archive. The build fails if a downloaded archive does not match its recorded SHA-256.

For each tagged source release, the same GitHub Release provides a matching `Release-Source.tar.gz`, its SHA-256 checksum, and a standalone third-party source manifest. The archive contains the exact tagged project tree and verified source inputs for the added video tools and helper. It is not described as complete corresponding source for the prebuilt playback dylibs used only during local and CI builds.

The project must not publish an application binary until its complete playback stack has been rebuilt from pinned, available source and the exact corresponding source, build scripts, and applicable notices can be delivered for that binary. Anyone independently distributing an application binary is responsible for meeting GPLv3 and all applicable third-party license requirements for the exact binaries they distribute.
