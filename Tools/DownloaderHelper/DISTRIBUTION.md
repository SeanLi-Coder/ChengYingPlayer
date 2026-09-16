# Download-center runtime distribution

The native download center preserves the complete MIT-licensed `rednote_downloader`
source at commit `e532e4fcd74bce4dfe730e49b8f1b49adceff62e`. Its engine, web UI,
download policies, quality validation, task recovery, and browser-cookie behavior
are retained. `vendor/rednote/LICENSE` remains part of the source and bundle.

The helper is built with the existing checksum-pinned CPython 3.13.2 and PyInstaller
toolchain. `requirements-runtime.in` records versions from the proven upstream
environment; `requirements-runtime.txt` pins the exact macOS arm64 wheels and their
SHA-256 hashes. `runtime-artifacts.json` records those wheel URLs and versions.
`runtime-sources.json` also fixes matching source distributions for every runtime
wheel, the matching Playwright Python/core repositories, Node 24.18.1, and native
libraries recorded by CPython 3.13.2's macOS installer recipe. `rust-sources.json`
records a conservative superset of registry crates from pydantic-core/watchfiles
Cargo.lock files, including build/development/other-target packages; it does not
claim every listed crate is linked into the application. The exact wit-bindgen
repository supplements its runtime crate's omitted standalone license files.
The two pinned Rust-based wheels contain the Rust commit
`59807616e1fa2540724bfbac14d7976d7e4a3860` (1.95.0) in their compiled standard-library
paths; the matching official Rust source distribution and notices are retained too.
`source_materials.py package <directory>` verifies and packages those archives;
`source_materials.py notices <directory>` retains their original legal notices.

`build_helper.sh` creates a native PyInstaller **BUNDLE** application at
`deps/download-center/DownloadCenter.app`. The player embeds this signed application
at `Contents/Helpers/DownloadCenter.app`. The console bootloader retains its stdin/stdout
protocol; `LSBackgroundOnly` and `LSUIElement` keep the helper out of the Dock.
Its real executables live in `Contents/MacOS`, native libraries and the Playwright
Node driver live in `Contents/Frameworks`, and Python sources, web assets, and notices
live in `Contents/Resources`. PyInstaller's cross-links preserve package-relative
lookups without treating scripts as nested code or hiding binaries among resources.
The containing player is signed without recursively signing the helper's contents.
The regression smoke test signs a minimal containing application and checks that
resource tampering is detected and no signature is stored in file extended attributes.
The launcher, Playwright Node driver, Python extensions, CA bundle,
yt-dlp extractors, and EJS JavaScript files are bundled. Starting the application
never creates a virtual environment, installs pip packages, or downloads a browser.

The native adapter reuses Playwright's sealed Node executable for yt-dlp's EJS
solver by absolute path. Deno is not included or installed. The preserved upstream
source is unchanged; only the native helper overrides its JavaScript runtime
selection. Cookies, proxy routing, format/quality policies and retries are retained.
The frozen smoke test solves synthetic n/signature challenges through the actual
yt-dlp Node provider and EJS parser without network access. Node's complete LICENSE
matches the corresponding official 24.18.1 source archive byte for byte.

Builds require an isolated virtual environment containing only the pinned runtime
and build dependencies, plus pip. The guard rejects unrelated installed packages
before PyInstaller can discover their optional imports. Keep tests in a different
environment; test-only HTTP clients must not enter the distributed helper.
Deno remains a test-only dependency to execute the preserved upstream's original
regression suite; it is absent from the runtime lock, clean build and app bundle.

The bundled Playwright 1.62.0 Node executable requires **macOS 13.5 or later**.
This applies only to the download center, not the player's existing local tools.
Google Chrome is a separately installed user application: the original engine uses
`channel="chrome"` and reads only the profile selected for an authorized task.
Google Chrome, Chromium binaries, user profiles, cookies, tokens, and downloads are
not embedded or redistributed. WebKit cookies are not substituted for Chrome's
existing login state.

Bundled notices are collected from every pinned runtime distribution, including
Playwright's Apache-2.0 notices, its Node.js license and third-party notices,
yt-dlp's Unlicense, EJS's Unlicense/MIT/ISC notices, Mutagen's
GPL-2.0-or-later notice, Certifi's MPL-2.0 notice, and all other wheel licenses.
The application reproduces this directory under `Contents/Resources/Legal/DownloadCenter`.
The main application's GPLv3 and existing CPython/PyInstaller notices also apply.
Setuptools' embedded backports, jaraco, packaging, wheel, and other vendored runtime
notices are collected as well; their sources reside in the pinned setuptools archive.

Binary releases must include these notices and provide the matching release source
archive, including Mutagen's GPL-covered source and Certifi's MPL-covered source.
The release source archive is provided alongside the DMG on the same GitHub Release.
Source availability for this runtime does not replace the separate playback-stack
source/build/notice verification. Anyone changing the locked components must update
their source inputs, notices and matching build records before redistribution.

The existing local-only FFmpeg/FFprobe binaries are reused without broadening their
network protocol support. yt-dlp downloads and locally remuxed audio/video work via
the preserved engine; formats requiring FFmpeg itself to open a network stream are
not added by this integration and may report an unsupported protocol.
