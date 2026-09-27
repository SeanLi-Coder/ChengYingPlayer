# SDR color-state regression

Run on macOS with Command Line Tools:

```sh
bash Tools/HDRColorStateTests/run.sh
```

The runner extracts and compiles the complete production `setICCProfile` method,
the fallback color-space declaration from `VideoView.swift`, and the
`PlayerCore.playbackRestarted` and `refreshEdrMode` methods. It uses genuine
macOS sRGB and Display P3 color spaces with recording boundaries for mpv, the
layer, screens and preferences. No application preference domain, personal media
or network is accessed. The temporary compiler output is removed after the run.

The cases cover HDR-to-SDR transitions, stale renderer state with an unchanged
layer profile, explicitly disabled ICC, a failed and subsequently successful ICC
submission, and unavailable screens or profiles. They assert matching renderer
output and layer color-space tags, ICC option ordering, preservation of the ICC
choice, and clearing of stale EDR, target brightness and screenshot state.
Playback cases verify that a new file restores color state even when its color
tags match the previous file, a paused first frame still receives the update,
and ordinary seeks or loop restarts do not repeat it. The actual `PlayerState`
enum and production refresh guards prevent color setup for inactive players or
unloaded windows. Existing loop, time, filter, flag-clearing and now-playing
operations remain covered through recording boundaries.

This is a compiled state-transition regression, not a GPU render test or physical
HDR display acceptance. The existing ICC render suite independently exercises the
real libmpv profile bridge. `HDR_COLOR_STATE_SOURCE_ROOT` can select a candidate
source tree to verify that regressions in the production method are detected.
