# Native media information window checks

Run `bash Tools/MediaInfoTests/WindowTests.sh` on macOS with a WindowServer session.
The test compiles only the production models, window controller, and shared native
style, with a deterministic fake reader. A temporary application bundle includes
the production English, Simplified Chinese, and Traditional Chinese strings;
each language runs in a fresh process and must resolve its actual localized title.
No media, mpv, ffprobe, playback state,
network access, or user clipboard is used.

The checks exercise serialized background reads, stale completion isolation,
source changes, both controller and native titlebar closing, cancellation tokens,
hidden-window behavior, errors and refresh, native selectable values, explicit
unknown values, a private pasteboard, long paths, actual vertical scrolling, and
minimum-size footer layout. The same production content is rasterized in Aqua and
Dark Aqua at minimum and standard requested window sizes. Each layout is captured
at its native backing density and explicitly at 1x and 2x. The test logs requested,
window frame, actual content, backing, and bitmap sizes. Native bitmap dimensions
must exactly match `convertToBacking` for the actual content bounds, rather than
assuming a requested window size survives WindowServer screen constraints. Every
PNG must decode with the exact expected dimensions and contain visible,
nonuniform interface pixels; light and dark images must differ at every density.
The actual content must still respect the production minimum layout size.

Set `MEDIA_INFO_SNAPSHOT_DIR=/absolute/output/path` to retain `media-info-light.png`
and `media-info-dark.png` under each language's subdirectory for visual review.
Additional files use `-1x` / `-2x` density suffixes and `media-info-minimum-*` names.
Without this option, the temporary
executable and snapshots are removed when the test exits.
