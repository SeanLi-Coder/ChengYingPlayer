# Third-party notices for bundled video tools

A locally built ChengYingPlayer application contains separate `ffmpeg`, `ffprobe`, and `chengying-video-tools-helper` executables. Exact media-tool source inputs and matching source distributions for the helper toolchain are fixed in [`other/third_party_sources.sh`](../other/third_party_sources.sh); exact Python build-wheel versions and hashes are fixed in [`Tools/VideoToolsHelper/requirements-build.txt`](../Tools/VideoToolsHelper/requirements-build.txt). Local and CI builds verify the applicable downloads by SHA-256. The project currently publishes source-only releases and does not distribute these executables.

## FFmpeg video tools

The bundled `ffmpeg` and `ffprobe` executables are built from the following source code:

| Component | Exact version | License used by this build | Source |
| --- | --- | --- | --- |
| FFmpeg | 9.0.1 | GPLv3-or-later build (`--enable-gpl --enable-version3`) | <https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz> |
| x264 | r3222, commit `b35605ace3ddf7c1a5d67a2eb553f034aef41d55` | GPLv2-or-later | <https://code.videolan.org/videolan/x264/-/tree/b35605ace3ddf7c1a5d67a2eb553f034aef41d55> |
| x265 | 4.3 | GPLv2-or-later | <https://github.com/Multicorewareinc/x265/releases/tag/4.3> |

x264 and x265 are statically linked into the FFmpeg executables. Because both codec libraries allow use under later GPL versions and this FFmpeg configuration enables GPLv3 components, those executables are conveyed under GPLv3-or-later. The application as a whole remains GPLv3 under the repository [`LICENSE`](../LICENSE).

A built application includes the applicable FFmpeg, x264, and x265 license texts in `Contents/Resources/Legal`. The source-only release includes the exact verified source archives and build scripts used to recreate these added executables.

## Frozen local helper

The `chengying-video-tools-helper` executable contains the project's Python source plus a frozen Python runtime produced with:

| Component | Exact version | License | Source |
| --- | --- | --- | --- |
| CPython | 3.13.2 | Python Software Foundation License Version 2 and the historical licenses reproduced in CPython's `LICENSE` | <https://www.python.org/downloads/release/python-3132/> |
| PyInstaller | 6.22.2 | GPLv2-or-later with the PyInstaller Bootloader Exception; embedded runtime hooks may use Apache-2.0 | <https://pypi.org/project/pyinstaller/6.22.2/> |

The PyInstaller Bootloader Exception permits the compiled bootloader and related files to be embedded in and distributed with the application without imposing additional restrictions on the combined executable. The helper's own source remains part of this GPLv3 project.

The PyInstaller build environment also pins `altgraph` 0.17.5 (MIT), `macholib` 1.16.4 (MIT), `packaging` 26.3 (Apache-2.0 OR BSD-2-Clause), `pyinstaller-hooks-contrib` 2026.7 (Apache-2.0 and GPLv2 notices), and `setuptools` 84.0.0 (MIT). These packages are build tools rather than application features; their versions and wheel hashes are fixed in [`Tools/VideoToolsHelper/requirements-build.txt`](../Tools/VideoToolsHelper/requirements-build.txt).

A built application reproduces the complete CPython and PyInstaller license files, the notices for PyInstaller's embedded `waflib` and `zlib` bootloader components, and the primary notices for every pinned helper build dependency in `Contents/Resources/Legal`. The release source archive includes the exact source distributions used by the source build process.

## Integrity and source availability

The authoritative checksums, filenames, and download URLs are stored in [`other/third_party_sources.sh`](../other/third_party_sources.sh) and reproduced as `SOURCE_MANIFEST.txt` in both a locally built application bundle and the release source archive. The build fails if a downloaded archive does not match its recorded SHA-256.

For each tagged source release, the same GitHub Release provides a matching `Release-Source.tar.gz`, its SHA-256 checksum, and a standalone third-party source manifest. The archive contains the exact tagged project tree and verified source inputs for the added video tools and helper. It is not described as complete corresponding source for the prebuilt playback dylibs used only during local and CI builds.

The project must not publish an application binary until its complete playback stack has been rebuilt from pinned, available source and the exact corresponding source, build scripts, and applicable notices can be delivered for that binary. Anyone independently distributing an application binary is responsible for meeting GPLv3 and all applicable third-party license requirements for the exact binaries they distribute.
