# Scaler LUT causal regression

This isolated command-line test uses a real CGL Apple software renderer and a
2-by-256 `GL_RGBA32F` LUT. It uses no application bundle, user settings, browser,
media, Core Animation layer, production installation, or persistent GL cache.
The executable and generated header live in a disposable temporary directory.

The six valid coefficients are finite, exactly representable constants summing
to one. Only the two unused lanes of each row change between finite, NaN,
positive infinity, negative infinity, and corrected cases. The corrected loop is
extracted from the actual repository backport patch rather than reimplemented in
the test. The runner rejects a patch outside that reviewed single-hunk shape.

```sh
python3 -B Tools/ScalerLUTTests/run.py --compile-only
python3 -B Tools/ScalerLUTTests/run.py
```

Use `--patch PATH` to compile against a different explicitly reviewed copy of the
same backport. Do not run the rendering command concurrently with other graphics
diagnostics. `--compile-only` never executes the binary or creates a GL context.

The shader samples both texels at phases 0, 0.25, 0.5, and 0.75 using the same
`LUT_POS` mapping as mpv. Each pixel, finite baseline, nearest-filter control,
poisoned linear sample, and repaired linear sample is reported. The test verifies
the full uploaded LUT, all six useful output coefficients, and corrected padding.
Coefficient comparisons are exact: identical rows with binary-exact coefficients
do not need a rounding tolerance. GL object deletion and CGL teardown are checked.
There is no fast-math compilation or CPU substitute for the GL negative control.

Exit status:

- `0`: poisoned linear sampling actually contaminated a useful coefficient, while
  the baseline, nearest controls, and every corrected case preserved coefficients.
- `77`: the valid controls passed, but this renderer did not reproduce poisoned
  useful coefficients. This is **not applicable**, not a passing causal regression.
- `1`: compilation, graphics setup, a control, corrected output, or cleanup failed.

This deliberately exercises `RGBA32F` to isolate interpolation from half-float
conversion. It does not replace the real mpv pipeline's texture-format selection
or the existing 4K close/reopen release assertions. The separate CPU boundary tests cover kernel
sizes and allocation bounds. Non-finite sampling behavior is renderer-dependent;
the test reports observations and does not claim a universal GL driver rule.

Verified locally on 2026-10-09 with `Apple Software Renderer`,
`4.1 APPLE-23.1.1`: each NaN, positive-infinity, and negative-infinity padding case
contaminated first-texel B/A at all four phases under linear sampling (24 useful
lanes total). Nearest controls remained correct. The actual backport's padding
loop restored every useful coefficient exactly in all cases. Both compile-only
and full-render commands exited successfully. This is isolated causal evidence,
not a claim that the separate player release gate has passed.
