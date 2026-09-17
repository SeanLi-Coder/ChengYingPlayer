# Installed video-summary source smoke

`smoke_helper.py --helper PATH --ffmpeg PATH --ffprobe PATH` exercises the source
helper from source or from its installed, signed application bundle. It uses only
invalid URLs and fresh temporary directories: it never accesses a website,
browser profile, login cookie, model, private report, or normal download job.

The test checks the real JSONL entry point, rejection of unsupported schemes and
credential-bearing URLs, one terminal event with the original request identity,
exit while the parent pipe remains open, and absence of normal downloader state.
Release CI also runs it against the frozen helper so packaging cannot accidentally
omit the source-acquisition module.

This smoke does not prove website availability, recognition accuracy, or summary
quality. Separate mocked regression tests cover parsing, source selection,
downloading, progress, cancellation, and report generation.

`runtime_smoke.py` is an optional additional Metal check. Run it with the pinned
AI runtime's Python on an Apple Silicon Mac. It generates four tokens using a
tiny, randomly initialized Qwen hybrid-attention graph in BF16 with its cache.
It does not download weights or require 96 GiB of memory, and must not be cited
as a full-model quality or performance benchmark.

`media_smoke.py --ffmpeg PATH --ffprobe PATH` generates short synthetic AAC and
FLAC files, exercises both real restricted probes and speech-audio extraction,
checks 16 kHz mono analysis and measured progress, and rejects a local reference
playlist disguised as an audio container. CI runs it against both the test
FFmpeg and the installed application's media executables.
