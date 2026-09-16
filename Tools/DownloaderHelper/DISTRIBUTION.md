# Download-center runtime distribution

The native download center preserves the complete MIT-licensed `rednote_downloader`
source at commit `e532e4fcd74bce4dfe730e49b8f1b49adceff62e`. Its engine, web UI,
download policies, quality validation, task recovery, and browser-cookie behavior
are retained. `vendor/rednote/LICENSE` remains part of the source and bundle.

The helper is built with the existing checksum-pinned CPython 3.13.2 and PyInstaller
toolchain. `requirements-runtime.in` records versions from the proven upstream
environment; `requirements-runtime.txt` pins the exact macOS arm64 wheels and their
SHA-256 hashes. `runtime-artifacts.json` records those wheel URLs and versions.
These are binary-wheel inputs, not a claim of complete corresponding source for
every embedded native dependency.

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
The launcher, Deno executable, Playwright Node driver, Python extensions, CA bundle,
yt-dlp extractors, and EJS JavaScript files are bundled. Starting the application
never creates a virtual environment, installs pip packages, or downloads a browser.

The bundled Playwright 1.62.0 Node executable requires **macOS 13.5 or later**.
This applies only to the download center, not the player's existing local tools.
Google Chrome is a separately installed user application: the original engine uses
`channel="chrome"` and reads only the profile selected for an authorized task.
Google Chrome, Chromium binaries, user profiles, cookies, tokens, and downloads are
not embedded or redistributed. WebKit cookies are not substituted for Chrome's
existing login state.

Bundled notices are collected from every pinned runtime distribution, including
Playwright's Apache-2.0 notices, its Node.js license and third-party notices,
yt-dlp's Unlicense, EJS's Unlicense/MIT/ISC notices, Deno's MIT notice, Mutagen's
GPL-2.0-or-later notice, Certifi's MPL-2.0 notice, and all other wheel licenses.
The application reproduces this directory under `Contents/Resources/Legal/DownloadCenter`.
The main application's GPLv3 and existing CPython/PyInstaller notices also apply.

The project retains **source-only releases**. This integration does not authorize
publishing an application binary or establish complete corresponding source for
the prebuilt playback stack, Node, Deno, or all transitive native components. Anyone
redistributing a built application must review the exact binaries and fulfill all
applicable license, notice, and corresponding-source requirements first.

The existing local-only FFmpeg/FFprobe binaries are reused without broadening their
network protocol support. yt-dlp downloads and locally remuxed audio/video work via
the preserved engine; formats requiring FFmpeg itself to open a network stream are
not added by this integration and may report an unsupported protocol.
