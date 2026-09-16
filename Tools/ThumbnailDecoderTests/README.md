# Actual thumbnail decoder regressions

After fetching the playback dependencies and building the bundled media tools,
run `bash Tools/ThumbnailDecoderTests/run.sh` on macOS with Command Line Tools.
`THUMBNAIL_TEST_FFMPEG` can explicitly select another fixture-generation binary.

The test compiles the complete production `FFmpegController.m` with Address
Sanitizer and links the application's actual playback FFmpeg libraries. Only
logging and delegate recording are test fixtures. A Swift conformance check uses
the actual Objective-C header with the Intel macOS 10.15 deployment target.

Generated fixtures cover 4K H.264 with B-frames, nonzero transport-stream PTS,
and a stream changing from 640x360 to 320x240. The latter must yield both expected
thumbnail heights, proving the second frame geometry was decoded. Other cases
exercise malformed/missing/audio-only input repeatedly, descriptor and memory
growth guards, invalid dimensions/counts, the total decoded-thumbnail budget,
running cancellation, completion already queued on the main thread, generation
propagation, main-thread delegates, and controller release.

All media is generated in a disposable temporary directory. No personal video,
playback configuration, or application cache is read. Deliberately malformed
fixtures can emit FFmpeg diagnostics; assertions and the process exit status
determine the result. This tests the independent thumbnail decoder, not the full
player's multi-hour rendering or HDR output.
