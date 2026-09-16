# ChengYing brand assets

`ChengYingIconMaster.png` is the source image for the macOS application icon.
The high-tech design combines a glass play prism, a titanium frame, and a precise
diagonal cut seam on a dark navy tile with cyan and violet edge lighting.
The rounded tile is surrounded by transparent padding.

The master was generated and refined with the built-in OpenAI image generation
tool on 2026-09-16. The exact prompt set is recorded in [IconPrompt.md](IconPrompt.md).
It excludes third-party logos, text, and watermarks.

From the repository root, run `./other/update_app_icons.sh` to generate the icon
renditions with the macOS `sips` tool, or use `--check` to validate the assets:

- `iina/Assets.xcassets/AppIcon.appiconset`: release builds.
- `iina/Assets.xcassets/AppIconDebug.appiconset`: debug builds.
- `iina/Assets.xcassets/AppIconBeta.appiconset`: beta builds.
- `iina/Assets.xcassets/AppIconNightly.appiconset`: nightly builds.
- `iina/Assets.xcassets/Icons/iina_arrow.imageset/iina-arrow.png`: initial window.

The About window uses the application icon automatically. The main README uses
the master directly. Document-type icons are separate and are not changed by
this script.
