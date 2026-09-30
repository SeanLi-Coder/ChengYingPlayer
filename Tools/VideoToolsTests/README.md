# Native video tools regression checks

Run `bash Tools/VideoToolsTests/run.sh` to compile the AppKit controller and
rotation coordinator tests using playback doubles. These tests do not exercise
the real mpv renderer or the bundled helper process.

The native checks cover persistent preview/confirmation actions at 320- and
360-point widths and 240/300/350/400/600-point heights, with long scrollable
failure details. They also exercise temporary preview over an existing keyboard
A/B loop, including edited ranges, stop, panel close, unload, and the next media
generation. Explicitly clearing A/B remains a separate action.
Task manager checks exercise known Dolby Vision clip diagnostics in all three
languages while retaining exact technical details and unknown helper errors.

Automatic-preview cases use a visible native field editor, actual change
notifications, and a running playback-controls timer. They cover debouncing,
marker buttons, invalid pending edits, rounded EOF endpoints, and navigation
outside temporary previews while retaining independently configured A/B loops.
Use `--language en --preview-case markers` for an isolated case. Add
`--controller-ref 9f2636a3` to reproduce the previous controller's failure using
an existing local commit; the runner does not fetch source or replace the rest
of the playback implementation. Test apps are isolated and retired using
`TestAppWorkspace`.

The input fixture waits for a key, laid-out window and observes an actual
playback refresh with invalid input before measuring debounce separately.
It checks the production timer's 350 ms deadline, cancellation on new input,
and every observable pre-deadline state without assuming timely run-loop
delivery. To exercise delayed dispatch and a smaller content viewport, run:

```sh
python3 -B Tools/VideoToolsTests/run.py --preview-case input --preview-case markers \
  --preview-repeat 3 --preview-window-height 600 --preview-run-loop-stall 0.42
```

For actual decoded frames, run `python3 -B Tools/ClipPreviewLiveTests/run.py`
after preparing the pinned playback dependencies. This runs the production
controller and bridge with real libmpv software rendering and extracted
production playback commands. The default input is synthetic; an explicitly
authorized local video can be opened read-only with `--media /path/to/video.mp4`.
No source media is copied or uploaded. The 320-by-180 software framebuffer does
not establish GPU, HDR, audio-quality or full-application keyboard acceptance.
The rotation-restoration fixture uses 180 degrees: 90-degree rendering exposed
a software-renderer crop assertion, so this fixture does not claim that path is
validated. Normal player rendering uses a different renderer.
The live debounce check timestamps actual mpv seek and unpause submissions;
`CHENGYING_PREVIEW_RUN_LOOP_STALL=0.42` exercises delayed timer delivery there
as well. Readiness and playback transitions use bounded condition waits rather
than treating a short sleep as proof that decoding or window activation ended.

To capture the real AppKit control hierarchy in English, Simplified Chinese,
and Traditional Chinese (both appearances), use an ignored output directory:

```sh
CHENGYING_CAPTURE_DIR="$PWD/.build/clip-preview-captures" bash Tools/VideoToolsTests/run.sh
```

The `active-failure-350` images show a valid preview status next to long failure
details. These are isolated control fixtures, not evidence of a rendered video
or a completed export.

## Real App rotation smoke

Use a signed App bundle on a macOS desktop with no other player instance running:

```sh
python3 -B Tools/VideoToolsTests/app_rotation_smoke.py \
  --app /path/to/ChengYing.app --source /path/to/sample.mp4 \
  --mode ipc --rounds 30 --interval 0.006 --keep-artifacts
```

The supplied video is copied into a new temporary directory. The smoke leaves
the original input untouched and uses process argument preferences to disable
playback history, recent files, resume positions, thumbnails, and automatic
update checks. It never runs `defaults write`. Without `--source`, it generates
a short H.264 test video with the App's bundled FFmpeg.

`--mode ipc` changes `video-rotate` through the real mpv connection, alternating
playing and paused bursts. It verifies the App survives, keeps the same source,
and continues decoding. It **does not cover permanent rotation or native keyboard
dispatch**. Repeat with `--hwdec no` to compare software decoding with the default
`--hwdec auto` behavior; the effective decoder is printed after the file opens.

`--mode keyboard` compiles `RotationKeyDriver.swift` and sends left Command+Shift
L/R key events only to the newly launched test App's PID. It exercises cumulative
permanent rotation, checks a newly generated final-angle export with the bundled
FFprobe, and decodes its first second with FFmpeg. It accepts the helper's supported
output containers (including MP4 inputs exported as MOV), verifies the baked
dimensions and absence of a remaining display transform, and checks that source
playback continues. The runner requires preexisting event-post
permission and fails without launching the App if permission is absent. It never
requests permission or changes Accessibility settings. `--mode auto` (the default)
falls back to the explicitly reported IPC-only scope when permission is missing.

`--keep-artifacts` prints the temporary directory containing the copied video,
App log, and any rotation exports. Otherwise that test directory is removed when
the run ends. A successful IPC run cannot establish that the permanent-rotation
shortcut is free of crashes; retain that distinction when reporting results.

Run the output-selection and metadata oracle checks without launching the App:

```sh
python3 -B -m unittest discover -s Tools/VideoToolsTests -p test_rotation_smoke.py
```
