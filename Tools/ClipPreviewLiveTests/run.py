#!/usr/bin/env python3
"""Run native editing against the shipped libmpv in an owned disposable app."""
import argparse
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from other.test_app_workspace import TestAppWorkspace


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--media", type=Path, help="Optional local video, opened read-only; never copied or uploaded")
    parser.add_argument("--controller-ref", help="Compare an existing git revision of the production controller")
    parser.add_argument("--parent-ref", help="Compare an existing git revision of the production settings parent")
    parser.add_argument("--core-ref", help="Compare an existing git revision of the production playback methods")
    parser.add_argument("--build-only", action="store_true", help="Check compilation without opening any test windows")
    parser.add_argument("--case", choices=["all", "opening", "editing", "markers", "navigation", "boundary", "precision",
                                           "invalid", "restore", "chrome-autohide", "media-reload", "fullwidth",
                                           "landing", "anchor"], default="all")
    args = parser.parse_args()
    if args.media and not args.media.is_file():
        parser.error("The media argument must be an existing local file")
    def resolve(reference, description):
        if not reference:
            return None
        try:
            return subprocess.check_output([
                "git", "rev-parse", "--verify", "--end-of-options", f"{reference}^{{commit}}"
            ], cwd=ROOT, text=True).strip()
        except subprocess.CalledProcessError:
            parser.error(f"The {description} reference must resolve to an existing commit")

    controller_ref = resolve(args.controller_ref, "controller")
    parent_ref = resolve(args.parent_ref, "parent")
    core_ref = resolve(args.core_ref, "playback core")
    tests = ROOT / "Tools/ClipPreviewLiveTests"
    with TestAppWorkspace(prefix="clip-preview-live-") as directory:
        work = Path(directory)
        app = work / "ClipPreviewLiveTests.app"
        contents = app / "Contents"
        executable = contents / "MacOS/ClipPreviewLiveTests"
        executable.parent.mkdir(parents=True)
        resources = contents / "Resources"
        resources.mkdir()
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "io.chengying.tests.clip-preview-live",
            "CFBundleExecutable": executable.name,
            "CFBundleName": "ClipPreviewLiveTests",
            "CFBundlePackageType": "APPL",
            "LSUIElement": True,
        }))
        for language in ["en", "zh-Hans", "zh-Hant"]:
            target = resources / f"{language}.lproj"
            target.mkdir()
            for name in ["Localizable.strings", "MediaInfo.strings"]:
                shutil.copyfile(ROOT / "iina" / f"{language}.lproj" / name, target / name)
        extract = ["xcrun", "swift", str(tests / "extract.swift"), str(ROOT), str(work), "-", "-"]
        for index, (reference, name) in enumerate([(parent_ref, "QuickSettingViewController.swift"),
                                                   (core_ref, "PlayerCore.swift")], start=5):
            if reference:
                baseline = work / name
                baseline.write_bytes(subprocess.check_output(["git", "show", f"{reference}:iina/{name}"], cwd=ROOT))
                extract[index] = str(baseline)
        subprocess.run(extract, check=True)
        controller = ROOT / "iina/VideoTools/VideoToolsViewController.swift"
        if controller_ref:
            controller = work / "VideoToolsViewController.swift"
            controller.write_bytes(subprocess.check_output([
                "git", "show", f"{controller_ref}:iina/VideoTools/VideoToolsViewController.swift"
            ], cwd=ROOT))
        media = args.media.resolve() if args.media else work / "generated-motion.mp4"
        if not args.media:
            # A high-resolution timescale preserves a fractional final duration.
            subprocess.run([str(ROOT / "deps/executable/ffmpeg"), "-nostdin", "-hide_banner", "-loglevel", "error",
                            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30000/1001",
                            "-frames:v", "240", "-c:v", "libx264", "-preset", "ultrafast",
                            "-pix_fmt", "yuv420p", "-video_track_timescale", "90000", str(media)], check=True)
        renderer = work / "Renderer.o"
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-c", str(tests / "Renderer.m"),
                        "-I", str(ROOT / "deps/include"), "-o", str(renderer)], check=True)
        sources = [
            "iina/Updates/UpdateWorkAdmission.swift", "iina/MPVOption.swift", "iina/MPVProperty.swift",
            "iina/MPVCommand.swift", "iina/MPVHook.swift", "iina/ChengYingStyle.swift",
            "iina/MediaInfo/MediaInfoModels.swift", "iina/VideoTools/VideoToolsModels.swift",
            "iina/VideoTools/VideoToolsShortcuts.swift", "iina/VideoTools/VideoToolsLoopPolicy.swift",
            "iina/VideoTools/VideoToolsRotationCoordinator.swift", "iina/VideoTools/VideoToolsPlayerBridge.swift",
        ]
        subprocess.run(["xcrun", "swiftc", "-o", str(executable), *[str(ROOT / item) for item in sources],
                        str(tests / "LivePlayer.swift"), str(work / "PlayerMethods.swift"),
                        str(work / "ExportBoundary.swift"), str(controller), str(work / "QuickSettingLifecycle.swift"), str(tests / "main.swift"),
                        str(renderer), "-import-objc-header", str(tests / "Renderer.h"),
                        "-I", str(ROOT / "deps/include"), str(ROOT / "deps/lib/libmpv.2.dylib"),
                        "-Xlinker", "-rpath", "-Xlinker", str(ROOT / "deps/lib")], check=True)
        result_code = 0
        if not args.build_only:
            result = subprocess.run([str(executable), "--media", str(media), "--case", args.case,
                                     "--synthetic" if not args.media else "--external"], timeout=150, check=False)
            result_code = result.returncode
    print("CLEANUP: owned test app unregistered and disposable workspace retired", flush=True)
    return result_code


if __name__ == "__main__":
    raise SystemExit(main())
