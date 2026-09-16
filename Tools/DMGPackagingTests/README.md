# Apple Silicon DMG packaging

Run the native packaging regressions on macOS:

```sh
bash Tools/DMGPackagingTests/run.sh
```

The tests compile synthetic ARM64 and Intel executables with Command Line Tools. They do **not** build or test the full player. Their deliberately marked `0.0.0-fixture` application contains placeholder helper executables and notices and must never be published. The tests exercise the production packager: read-only DMG creation and remount, Applications link, native launch from the mounted fixture, signature and byte preservation, source immutability, no-overwrite rules, ARM64 checks, missing components, escaped links, unresolved or build-machine dynamic dependencies, and signature tampering.

To package the real, already assembled and signed application:

```sh
bash other/package_dmg.sh \
  /absolute/build/Release/ChengYing.app \
  /absolute/existing-output-directory/ChengYingPlayer-v0.2.7-Apple-Silicon.dmg
```

The macOS build machine needs Python 3 and the system `codesign`, `ditto`, and `hdiutil` commands. Neither Python nor those build tools are installation prerequisites for the packaged player. The input application is never repaired or re-signed by this command. Its bundle identifier, required native tools, legal notices, all Mach-O ARM64 slices, internal symlinks, runtime search paths, dynamically linked dependencies, and deep strict code signature must pass before packaging.

The output directory must already exist. Neither the `.dmg` nor its `.dmg.sha256` sidecar may exist, including dangling symlinks. The packager uses private staging and mount directories, verifies the compressed read-only image and every mounted application file, checks the mounted code signature, and detaches the image before atomically publishing each output without replacement. It does not run Finder, install anything in `/Applications`, execute the input player, remove quarantine, disable Gatekeeper, or write into the source bundle. A failed detach preserves its private mounted directory rather than recursively removing a mounted filesystem.

The image presents `ChengYing.app` and an `Applications` folder link. Installation is a standard drag into Applications. An ad-hoc signature is **not** Developer ID signing or Apple notarization; the installer text explains that macOS may require the user to verify the download's origin and choose **Open Anyway** in Privacy & Security after the first launch attempt. Truly warning-free first launch needs a valid Developer ID signing identity and Apple's notarization service, which this packager does not claim to provide.

Release CI must also build and smoke-test the full application and publish matching corresponding source and license material. Passing this isolated fixture suite alone does not certify that the complete player launches, that every optional runtime-loaded plugin is reachable, or that downloaded subtitle models are already installed.
