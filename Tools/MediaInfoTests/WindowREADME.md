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
Dark Aqua; the images must differ and include the full content view.

Set `MEDIA_INFO_SNAPSHOT_DIR=/absolute/output/path` to retain `media-info-light.png`
and `media-info-dark.png` under each language's subdirectory for visual review.
Without this option, the temporary
executable and snapshots are removed when the test exits.
