# Video Tools Helper Protocol

The app launches one persistent helper process:

```text
chengying-video-tools-helper --ffmpeg /absolute/path/ffmpeg --ffprobe /absolute/path/ffprobe --stdio
```

The helper reads UTF-8 JSON Lines from standard input and writes UTF-8 JSON Lines to
standard output. Standard output never contains human-oriented logs. Protocol version 1
allows one active media task at a time.

## Startup

After validating both executable paths, the helper emits a `ready` event:

```json
{"type":"ready","protocol_version":1,"helper":"chengying-video-tools-helper","helper_version":"1.0.0","operations":["probe","clip","frames","rotate"],"max_frame_extraction_seconds":5.0,"default_frame_extraction_seconds":5.0,"supported_rotation_degrees":[90,180,270,360]}
```

An invalid executable path produces one `failed` event with `error_code` set to
`startup_error`, followed by exit status 2.

## Requests

Every request has a unique non-empty string `id` and a `command`.

Probe a local video:

```json
{"id":"probe-1","command":"start","operation":"probe","input_path":"/absolute/input.mov"}
```

Create a precise clip:

```json
{"id":"clip-1","command":"start","operation":"clip","input_path":"/absolute/input.mov","start":"00:00:10.250","end":"00:00:15.750","output_directory":"/absolute/output"}
```

Extract every frame from a range no longer than five seconds:

```json
{"id":"frames-1","command":"start","operation":"frames","input_path":"/absolute/input.mov","start":12.5,"end":17.5,"output_directory":"/absolute/output"}
```

`extract_frames` is accepted as an alias for `frames`. If `end` is omitted, the helper
uses five seconds after `start`, clamped to the source duration. If `output_directory`
is omitted for `clip` or `frames`, the source directory is used.

Permanently rotate a video clockwise:

```json
{"id":"rotate-1","command":"start","operation":"rotate","input_path":"/absolute/input.mov","degrees":90}
```

Rotation always creates a uniquely named file beside the source. It rejects an
`output_directory` field. Supported values are 90, 180, 270, and 360.

Cancel the active task by using its task id:

```json
{"id":"clip-1","command":"cancel"}
```

A separate cancellation request id can use `target_id`:

```json
{"id":"cancel-1","command":"cancel","target_id":"clip-1"}
```

The helper also accepts `ping` and `shutdown` commands. End-of-file or `SIGTERM`
cancels the active task, waits for partial output cleanup, and exits. `SIGINT` has the
same behavior. If the app must force termination after the grace period, it may send
`SIGKILL`; graceful cancellation should always be attempted first.

## Events

A start request first receives an `accepted` event:

```json
{"id":"clip-1","type":"accepted","operation":"clip","protocol_version":1}
```

Long-running work emits changed progress snapshots:

```json
{"id":"clip-1","type":"progress","operation":"clip","status":"running","progress":42.3,"message":"Creating a high-fidelity precise clip","elapsed_seconds":8.4,"eta_seconds":11.5,"protocol_version":1}
```

Successful processing returns an absolute published output path:

```json
{"id":"clip-1","type":"completed","operation":"clip","progress":100.0,"message":"Clip completed; the source video was not modified","elapsed_seconds":20.1,"eta_seconds":0.0,"output_path":"/absolute/output/input_clip_00-00-10_250-00-00-15_750.mp4","output_name":"input_clip_00-00-10_250-00-00-15_750.mp4","protocol_version":1}
```

A successful probe returns its result in `metadata`. Frame extraction completion also
contains `frame_count`. A cancelled task has type `cancelled` and never contains an
output path.

Failures have stable machine-readable `error_code` and human-readable `error` fields:

```json
{"id":"clip-2","type":"failed","operation":"clip","error_code":"media_error","error":"End time exceeds the video duration","protocol_version":1}
```

Known error codes are `startup_error`, `invalid_json`, `request_too_large`,
`invalid_request`, `busy`, `task_not_found`, `media_error`, `processing_failed`, and
`internal_error`.

## Output Safety

The helper never overwrites the source or an existing destination. It writes to an
owned partial file or directory, validates dimensions, codecs, pixel depth, color
metadata, audio parameters, duration, and rotation as applicable, and publishes only
after verification. Cancellation and failure remove owned partial output.
Dynamic HDR formats whose per-frame metadata cannot be preserved safely are rejected
before clipping or rotation; they are never silently converted to static HDR or SDR.
