# Native welcome design checks

Run `bash Tools/WelcomeDesignTests/run.sh` on macOS. The harness compiles the production welcome controller and shared AppKit style, substituting only playback, preferences, and nib loading. It does not require full Xcode or access the user's recent documents.

Tests exercise the real file-open and download actions, Return/keypad Enter, the history-free view tree, accessibility text, compact centered layout, and minimum-size constraints in English and Simplified Chinese. Set `CHENGYING_CAPTURE_DIR` to an output directory to render the actual native views in light/dark mode at default and minimum sizes.

The fixture populates its own last-file preferences, verifies that opening or reopening the home page does not read or delete them, and checks that history updates cannot recreate hidden file controls. A shadow document controller fails closed on any attempted history access. Theme changes still deliver real `UserDefaults` KVO from a worker queue. The harness uses its own bundle identifier and restores touched defaults after each run; it never changes the production app's preferences.

These checks do not replace the full application's Xcode build and Interface Builder compilation.
