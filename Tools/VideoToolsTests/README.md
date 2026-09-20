# Native video tools regression checks

Run `bash Tools/VideoToolsTests/run.sh` to compile the AppKit controller and
rotation coordinator tests using playback doubles. These tests do not exercise
the real mpv renderer or the bundled helper process.

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
