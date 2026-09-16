# Automatic subtitle matching regression tests

Run `bash Tools/AutoFileMatchingTests/run.sh` on macOS with Xcode command-line tools.

The suite compiles the complete production `AutoFileMatcher`, `FileInfo`, `FileGroup`, folder scanning, and atomic storage. The Objective-C edit-distance implementation and its constants are extracted mechanically from `ObjcUtils.m` and compiled without alteration. Only preferences and the playback boundary are doubles. The default automatic matching and final unmatched-file fallback both run; an unavailable mpv playlist snapshot prevents unrelated playback mutations.

Real temporary filenames reproduce the numeric substring collision where `Episode 1` claims `Episode 10`'s only subtitle before the latter video is visited. Tests also cover padded season names, grouped series, release/language affixes, literal punctuation, canonically equivalent NFC/NFD names, numeric prefixes, a valid later occurrence, existing nonnumeric substring behavior, and disabled matching. No real media or user subtitle files are read or modified.

Set `AUTO_FILE_MATCHER_SOURCE` to a previous production source file to run the same regressions against it. The original implementation fails the default-mode episode collision assertion.
