# Native drop routing boundary tests

Run `bash Tools/NativeDropRoutingTests/run.sh` on macOS. The complete production
`PlayerCore.openFromPasteboard` method is mechanically extracted unchanged.
Each case uses a real, uniquely named NSPasteboard, never the user's clipboard;
it releases that named pasteboard afterward. No app bundle or user media is used.

The app's media classifier, MPV commands and asynchronous compatibility manager
are explicit boundaries. Deferred subtitle/LUT operations must not issue MPV
commands before that manager completes. Cases replace the pasteboard contents
and release the drag object before completion to verify captured value semantics,
and cover cancellation, player lifetime, resolved paths, batches, legacy behavior,
filter failures and malformed payloads. The normal production drop method is not
replaced with a parallel implementation.

For native drops, `true` means the drag was accepted for asynchronous processing,
not that restore or filter installation succeeded. The existing compatibility
coordinator owns cancellation when the media changes or the player stops; these
tests prove the drop boundary respects its callback, not real decoding or restore.
Legacy synchronous LUT failure still returns `false` and no false success OSD is
emitted after a deferred failure. macOS 12 typechecking and Address Sanitizer are
included; the printed artifact directory preserves extracted source and results.

`NATIVE_DROP_TEST_SKIP_COMPATIBILITY=1 bash Tools/NativeDropRoutingTests/run.sh`
is a controlled negative run which disables only the two native handoff branches
in the extracted temporary method. It must fail the pre-restore command guard;
it is not a passing acceptance run. Normal extraction does not alter the method.
