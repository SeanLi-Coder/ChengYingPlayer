# Update activity regression tests

Run `bash Tools/UpdateActivityTests/run.sh` on macOS. The suite compiles the actual
gate, admission lock, process drain, update policy, and player-state model. Only
application/service boundaries are test doubles. No application is launched and
no user preferences, media, browser data, or network service are accessed.

Coverage includes asynchronous readiness, local/backend races, pending rotations,
paused playback, slideshow/conversion activity, cancellation generations, lease
failures, native admission, final termination guards, and a real owned helper
process that outlives the drain timeout and must never be terminated.
The second executable uses the real video helper transport and a temporary owned
Python helper to exercise graceful shutdown, cancellation, and three restarts.
All helper shutdowns reserve their retirement synchronously; cancelling an update
releases playback immediately but defers new helper work until the old pipe closes.

Downloader adapter tests are in
`Tools/DownloaderHelper/tests/test_update_maintenance.py` and run with pytest.
