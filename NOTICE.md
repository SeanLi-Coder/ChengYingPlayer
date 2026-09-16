# ChengYingPlayer Legal Notices

This file records the origin, modification status, copyright notices, and third-party attributions for this distribution. It supplements, and does not replace, the GNU General Public License in [`LICENSE`](LICENSE) or the component-specific notices in [`iina/Credits.rtf`](iina/Credits.rtf).

## Modified work

**Product name:** ChengYingPlayer / 澄影播放器

**Upstream project:** IINA

**Upstream version:** v1.4.4

**Upstream source:** <https://github.com/iina/iina/tree/v1.4.4>

**Upstream commit:** `c111221ea027466b79b40bfca054772d4851e06f`
**Modification date:** 2026-09-16 and later

ChengYingPlayer is a modified version of IINA v1.4.4. It is distributed under the GNU General Public License, version 3. The work must remain available under GPLv3, and recipients must retain the rights granted by that license.

The product name, application identity, user interface, local video tools, packaging, documentation, and other project-specific changes are modifications made after the upstream version identified above. Source-control history and release tags are retained so that downstream recipients can identify the exact source release. No application binary is currently published.

ChengYingPlayer is an independent project. It is not endorsed by, affiliated with, or supported by the IINA project or its maintainers. The IINA name and visual identity are not used to identify this modified product.

## Original copyright

The upstream application's bundled contribution notice states:

> IINA — Copyright © 2017–2026 Collider LI, et al.

Copyright notices in individual source files remain in effect and must not be removed. Copyright in later modifications belongs to the respective ChengYingPlayer contributors unless a modified file states otherwise.

## GPLv3 distribution requirements

When source or binary copies are distributed:

1. Keep [`LICENSE`](LICENSE), this notice, existing source-file copyright notices, and applicable third-party notices intact.
2. Mark the work as modified and provide the relevant modification date.
3. License the covered work as a whole under GPLv3 without adding restrictions that conflict with the license.
4. When object code is distributed, provide its complete corresponding source and the scripts needed to build and install that same object code. A moving default branch is not a substitute for the exact tagged source of a binary release.
5. When an application binary is distributed, preserve an accessible in-application legal notice containing the copyright, warranty, GPLv3, source, and third-party attribution information.

See [`LICENSE`](LICENSE) for the controlling terms. If this summary and GPLv3 differ, GPLv3 controls.

## Third-party components

The upstream application includes or depends on third-party software. In addition, local and CI application builds bundle four local media-tool executables and a separate download-center helper with its own runtime. The following list is not a substitute for the complete component licenses:

| Component | Copyright or project attribution | License notice |
| --- | --- | --- |
| libmpv / mpv | Copyright © the mpv developers | Retain the notice and terms bundled with the applicable mpv build. |
| FFmpeg 9.0.1 (`ffmpeg` and `ffprobe` tools) | Copyright © the FFmpeg developers | Built with `--enable-gpl --enable-version3`; the bundled tool executables are GPLv3-or-later. |
| x264 r3222, commit `b35605ace3ddf7c1a5d67a2eb553f034aef41d55` | Copyright © the x264 project | GPLv2-or-later; statically linked into the bundled FFmpeg tools. |
| x265 4.3 | Copyright © MulticoreWare, Inc. and x265 contributors | GPLv2-or-later; statically linked into the bundled FFmpeg tools. |
| CPython 3.13.2 | Copyright © 2001–2024 Python Software Foundation and other named licensors | Python Software Foundation License Version 2 and historical Python licenses. Embedded in the frozen local helper. |
| PyInstaller 6.22.2 | Copyright © the PyInstaller Development Team and named predecessors | GPLv2-or-later with the PyInstaller Bootloader Exception; applicable embedded runtime hooks use their stated licenses. |
| altgraph 0.17.5, macholib 1.16.4, packaging 26.3, pyinstaller-hooks-contrib 2026.7, setuptools 84.0.0 | Copyright © their respective contributors | Checksum-pinned helper build dependencies. Their MIT, Apache-2.0/BSD-2-Clause, and applicable GPLv2 notices are reproduced in a built application's Legal directory. |
| Just | Copyright © Just contributors | MIT License |
| PromiseKit | Copyright © Max Howell and contributors | MIT License |
| GRMustache | Copyright © Gwendal Roué | MIT License |
| Sparkle | Copyright © its named contributors | MIT License |

Exact upstream application notices are bundled in [`iina/Credits.rtf`](iina/Credits.rtf). Exact notices and source details for the added video-tool executables are recorded in [`Legal/THIRD_PARTY_NOTICES.md`](Legal/THIRD_PARTY_NOTICES.md) and [`other/third_party_sources.sh`](other/third_party_sources.sh).

The subtitle feature adapts the repository owner's earlier `subtitle_add` / 译幕 workflow. Its optional Qwen3 and Hy-MT2 weights and isolated AI runtime are downloaded directly from their official upstreams only at the user's request; they are not relicensed as GPLv3 or included in a source release. In particular, Hy-MT2 uses the Tencent HY Community License, not Apache-2.0. Exact asset locks and additional FreeType, HarfBuzz, FriBidi, libunibreak, and libass notices are documented in `Legal/THIRD_PARTY_NOTICES.md`.

## Current source-only release policy

The download center incorporates Original Media Downloader / 原迹下载器 (`rednote_downloader`), version 1.2.23, commit `e532e4fcd74bce4dfe730e49b8f1b49adceff62e`, copyright © 2026 Sean Li, under its retained MIT license. Its complete tracked source, except the upstream GitHub workflows, is preserved in `Tools/DownloaderHelper/vendor/rednote`; the two documented adaptation/test patches and per-file original/current hashes are recorded in `Tools/DownloaderHelper/upstream-manifest.json`. The native host and its integration code are modifications distributed under this project's GPLv3 license.

The separately frozen download runtime uses checksum-pinned dependencies, including yt-dlp, Playwright and its Node driver, Deno, FastAPI, and their dependencies. Their complete wheel/source provenance and collected notices are described in `Tools/DownloaderHelper/DISTRIBUTION.md` and `Legal/THIRD_PARTY_NOTICES.md`. Google Chrome and browser profiles are not redistributed. Downloader wheels and runtime binaries are not included in the source-only release, and the manifest is not a claim of complete corresponding source for an application binary.

The project's GitHub Actions workflow currently publishes source-only releases. It may build and smoke-test `ChengYing.app` inside an ephemeral runner, but it must not upload the application, a DMG, a ZIP, or any other application binary as an Actions artifact or GitHub Release asset.

Each tagged release contains a `Release-Source.tar.gz` archive, its SHA-256 checksum, and a standalone third-party source manifest. The archive is produced by [`other/package_release_source.sh`](other/package_release_source.sh) and contains the exact project source tree plus verified source distributions for the added FFmpeg tools, frozen helper runtime, and pinned helper build dependencies. Its source inputs are checksum-pinned, so a moving upstream branch or default branch cannot silently change those inputs.

This archive is a convenience source package for the source-only release. It is not represented as complete corresponding source for the prebuilt playback dylibs used during local and CI builds, because those binaries are not distributed by the project and their complete, exactly matching source/build record has not yet been closed. Public application-binary distribution is prohibited until the playback stack is rebuilt from pinned, available source and all complete corresponding source, build scripts, and applicable notices can be delivered with the binary.

A distributor who changes a dependency or its build options must update the notices, source manifest, checksums, and release source asset and must verify license compatibility before release. Anyone independently distributing object code must satisfy GPLv3 and all applicable third-party license obligations for the exact binaries they distribute.

## No warranty

This software is provided without warranty, to the extent permitted by applicable law. The complete warranty disclaimer and limitation of liability are contained in GPLv3 and the applicable third-party licenses.
