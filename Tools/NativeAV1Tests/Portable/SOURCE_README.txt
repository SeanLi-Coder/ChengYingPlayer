Corresponding source and notices for the standalone AV1 acceptance CLI

This package contains the GPLv3 ChengYing native decoder test and five FFmpeg
7.1.5 dylibs from the verified playback build. FFmpeg was configured with
--enable-gpl --enable-version3, --disable-autodetect and static dependency
resolution. The five dynamic dependencies are NOT a list of all incorporated
software: dav1d and applicable embedded codec/library code remain covered by
their own original notices. The playback build also enables libass and zimg;
the source bundle conservatively retains every input of that complete recipe,
including font/shaping dependencies and mpv/libplacebo build inputs. Superset
source inclusion is not a claim that all components are linked into this CLI.

Legal/LICENSE contains GPLv3. PROJECT_NOTICE.md and PROJECT_THIRD_PARTY_NOTICES.md
retain the project's upstream and modification attributions. These two general
project notices describe the full application; the application, download helper,
AI models, and libmpv are NOT executables included in this test package.
Legal/licenses/ preserves the original notices collected and verified byte for
byte against all sixteen locked playback source archives.

Legal/Corresponding-Source.tar.gz contains:
  * the exact CYNMediaDecoder.m/.h and native AV1 test source and fixtures;
  * the existing AV1 compiler/test runner and this portable packager/launcher;
  * the project LICENSE, NOTICE and upstream credits;
  * all sixteen SHA-256-locked playback source archives with source URLs;
  * the real playback build record, original license notices, FFmpeg configuration,
    compiler/SDK record, library/header digests, source patches and patched files;
  * the existing playback/subtitle build scripts, lock tables, all patch bytes,
    dependency verifier and a per-file corresponding-source SHA-256 manifest.

These materials are supplied together with the binary, not via a promise to
provide source later. They do not need to be extracted to run the acceptance
check. Preserve them and their notices when conveying this package further.
The work is provided without warranty; the individual license texts control.

For a source rebuild, extract the archive and enter ChengYingAV1-Source. On an
arm64 development Mac with the build tools documented by the scripts, run:
  SOURCE_CACHE_DIR="$PWD/third-party-sources" bash other/build_playback_libraries.sh "$PWD/deps"
  mkdir -p build
  python3 -B Tools/NativeAV1Tests/run.py --deps "$PWD/deps" --source-cache "$PWD/third-party-sources" --require-hardware
The existing runner requires a separate FFmpeg CLI with libdav1d to regenerate
independent synthetic reference frames. See Tools/NativeAV1Tests/README.md.
The packaged executable was compiled for macOS 26.0 using SDK 27.0 without a
sanitizer. Rebuilding requires development tools; RUNNING the supplied check does
not. Rebuilds must receive a new reviewed identity before use as official evidence.
The verifier's fixed hashes are acceptance provenance checks, not restrictions on
your GPL rights to study, modify, rebuild or redistribute the corresponding code.

The exact runtime binary/fixture/library hashes are in ../manifest.json.
SHA values and manifests in the same unsigned package detect accidental changes;
they do not authenticate an issuer or resist malicious rewriting of both scripts
and manifests. No Developer ID signature or Apple notarization is claimed.
