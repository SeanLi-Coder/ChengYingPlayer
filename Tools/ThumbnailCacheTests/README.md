# Thumbnail cache safety regressions

Run `bash Tools/ThumbnailCacheTests/run.sh` on macOS with Command Line Tools.

The complete production `ThumbnailCache` and `CacheManager` compile and execute
against a temporary cache directory. Only preferences, logging, cache location,
and the thumbnail container are boundary fixtures. Real AppKit/ImageIO JPEG
encoding, POSIX file I/O, concurrent dispatch queues, and filesystem eviction are
used. The suite runs with Address Sanitizer and includes Intel macOS 10.15
typechecking; no playback libraries or user files are needed.

Cases include truncated/negative/oversized block lengths, invalid timestamps,
non-JPEG images, compressed and decoded memory budgets, invalid versions,
descriptor cleanup, atomic replacement, concurrent writes, metadata matching,
repeated and failed eviction, symlink/directory preservation, and manual-clear
statistics invalidation. A failed replacement must preserve an existing valid
cache even when over quota; successful eviction must preserve the new target.
