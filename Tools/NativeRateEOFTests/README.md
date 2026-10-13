# Native rate-at-EOF reproduction

`bash Tools/NativeRateEOFTests/run.sh` compiles the production decoder, Session,
sample gate and output. It plays generated FFV1/PCM and H.264/AAC media to real
EOF, then compares an unchanged-rate control with `setRate(0.8)` before the first
resume. No ended snapshot or output event is fabricated. Samples stay silent;
the check concerns actual shared-clock state, not physical audible output.

The AppKit layer host is unshown and never becomes a key window. Coordinate this
runner with other renderer tests nonetheless. `BUILD_ONLY=1` only compiles.
Sources, dependencies and generated media are hashed; failure logs remain in the
owned `build/native-rate-eof.*` directory. No user files or preferences are read.

The original Session (`5542c2670f18`) reproduced the issue in
`build/native-rate-eof.XTH30V`: **34 passed, 2 failed**, exit 1. Both unchanged-rate
controls restarted normally. Both changed-rate cases reached real EOF at 1.2 s,
then `setRate(0.8)` changed the phase to paused at 1.199999 s. The first resume
briefly played at 1.2 s and immediately ended again instead of restarting.
Source, fixture and dependency checks succeeded. This preserves failing evidence;
it is not a production-fix or physical-audio acceptance claim.

## Fix and final evidence

The production change is limited to `NativePlaybackSession.setRate`: after the
existing media/revision/decoder checks, an ended session publishes its new rate
without seeking or flushing. The first explicit resume retains the existing
EOF-to-start behavior. No Core, menu, output renderer or loop policy is changed.

The final main test (`144097fdff3b`) additionally checks consecutive EOF rate
commands through an actual worker-to-main barrier, rejection of an unsupported
rate, unchanged stopped output queues, and an explicit seek to 0.4 s followed by
a rate change and resume from that position. Both formats retain their original
unchanged-rate controls.

| Run | Mode | Result |
| --- | --- | --- |
| `GY9B0L` | Normal | 64 passed, 0 failed; compile and execution exit 0 |
| `M7VAcc` | AddressSanitizer | 64 passed, 0 failed; compile and execution exit 0 |
| `h71aZc` | ThreadSanitizer | 64 passed, 0 failed; compile and execution exit 0 |
| `L528c1` | Remove only the EOF-rate branch in a copied Session | 52 passed, exactly 8 expected failures; compile exit 0, execution exit 1, verifier exit 0 |

All four use production Session
`aab38cba18651a86e7250e743a9af2e580ae50c67c3bc7ee150f937d6184d1af`,
the same main test, and runner `e94d5bba17fa`.
All source, generated object/executable, fixture and dependency checks passed.
No sanitizer findings were reported. The negative copy omits only the four-line
EOF guard and reproduces four exact EOF failures per format, while the ordinary
controls, explicit seeks and shutdown checks remain passing.

The verifier alone was strengthened after the three positive runs: it now checks
`dependency-validation.log` explicitly so a dependency error cannot masquerade
as the expected child exit 1. Its final hash is `9288baf968ee`; `L528c1` uses this
version and records it in the source manifest. The positive manifests contain
the earlier verifier `dcfe403cfdc9`; their compiled behavior, main assertions and
production Session are unchanged. They are not described as identical complete
tool manifests. Earlier 62-check runs `Wy694V` / `FwWSnb` and negative `zBjR6I`
remain preserved but are not the final evidence above.

Commands:

```sh
bash Tools/NativeRateEOFTests/run.sh
NATIVE_PLAYBACK_SANITIZER=address bash Tools/NativeRateEOFTests/run.sh
NATIVE_PLAYBACK_SANITIZER=thread bash Tools/NativeRateEOFTests/run.sh
NATIVE_RATE_EOF_NEGATIVE=1 bash Tools/NativeRateEOFTests/run.sh
# The previous command must exit 1, then validate its exact failures:
python3 Tools/NativeRateEOFTests/verify_negative.py build/native-rate-eof.L528c1
```

This validates the real Session/decoder/output clock, not the full application,
physical audio output, default-backend policy or target-machine hardware decoding.
