# Native welcome design checks

Run `bash Tools/WelcomeDesignTests/run.sh` on macOS. The harness compiles the production welcome controller and shared AppKit style, substituting only playback, preferences, and nib loading. It does not require full Xcode or access the user's recent documents.

Tests exercise local-file filtering, history privacy, resume, the real button actions, keyboard navigation, and minimum-size constraints in English and Simplified Chinese. Set `CHENGYING_CAPTURE_DIR` to an output directory to render the actual native views in light/dark mode with populated and empty histories.

Privacy refresh checks deliver real `UserDefaults` KVO changes from both the main thread and a worker queue, without manually reloading the controller. The harness uses its own bundle identifier and restores touched defaults after each run; it never changes the production app's preferences.

These checks do not replace the full application's Xcode build and Interface Builder compilation.
