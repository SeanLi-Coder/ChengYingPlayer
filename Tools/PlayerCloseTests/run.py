#!/usr/bin/env python3
"""Exercise the production rendering layer with real synchronous libmpv close calls."""
import argparse
import plistlib
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from other.test_app_workspace import TestAppWorkspace

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--priority", action="store_true", help="Check deterministic recursive render lock scheduling")
parser.add_argument("--layer-ref", help="Use an existing commit's ViewLayer for a negative control")
args = parser.parse_args()
reference = None
if args.layer_ref:
    reference = subprocess.check_output([
        "git", "rev-parse", "--verify", "--end-of-options", f"{args.layer_ref}^{{commit}}"
    ], cwd=ROOT, text=True).strip()

with TestAppWorkspace(prefix="player-close-") as directory:
    work = Path(directory)
    layer = ROOT / "iina/ViewLayer.swift"
    if reference:
        layer = work / "ViewLayer.swift"
        layer.write_bytes(subprocess.check_output(["git", "show", f"{reference}:iina/ViewLayer.swift"], cwd=ROOT))
    if args.priority:
        source = layer.read_text()
        marker = "private class MainThreadPriorityLock {"
        if source.count(marker) != 1:
            raise RuntimeError("The production priority lock extraction boundary changed")
        extracted = "import Cocoa\n" + source[source.index(marker):].replace(marker, "class MainThreadPriorityLock {", 1)
        if "func beforeUnlocking()" not in extracted:
            extracted += "\nextension MainThreadPriorityLock { func beforeUnlocking() {} }\n"
        lock_source = work / "Priority.swift"
        lock_source.write_text(extracted)
        binary = work / "PriorityTests"
        subprocess.run(["xcrun", "swiftc", "-o", str(binary), str(lock_source),
                        str(ROOT / "Tools/PlayerCloseTests/PriorityMain.swift")], check=True)
        subprocess.run([str(binary)], timeout=10, check=True)
        print("PASS: priority scheduling regression")
        sys.exit(0)
    executable = work / "PlayerCloseTests.app/Contents/MacOS/PlayerCloseTests"
    executable.parent.mkdir(parents=True)
    (executable.parent.parent / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "io.chengying.tests.player-close",
        "CFBundleExecutable": executable.name,
        "CFBundleName": "PlayerCloseTests",
        "CFBundlePackageType": "APPL",
        "LSUIElement": True,
    }))
    media = work / "generated.mp4"
    subprocess.run([str(ROOT / "deps/executable/ffmpeg"), "-nostdin", "-hide_banner", "-loglevel", "error",
                    "-f", "lavfi", "-i", "testsrc2=size=3840x2160:rate=60", "-t", "10",
                    "-c:v", "libx264", "-preset", "ultrafast", str(media)], check=True)
    sources = ["iina/Atomic.swift", "iina/Lock.swift", "iina/ReadWriteAtomic.swift",
               "iina/ReadWriteLock.swift", "iina/MPVOption.swift",
               "Tools/PlayerCloseTests/Boundary.swift", "Tools/PlayerCloseTests/main.swift"]
    subprocess.run(["xcrun", "swiftc", "-suppress-warnings", "-o", str(executable),
                    *[str(ROOT / path) for path in sources],
                    str(layer),
                    "-import-objc-header", str(ROOT / "Tools/PlayerCloseTests/Bridge.h"),
                    "-I", str(ROOT / "deps/include"), str(ROOT / "deps/lib/libmpv.2.dylib"),
                    "-Xlinker", "-rpath", "-Xlinker", str(ROOT / "deps/lib")], check=True)
    result = subprocess.run([str(executable), str(media)], timeout=390, check=False)
print("CLEANUP: owned test app unregistered and disposable workspace retired")
raise SystemExit(result.returncode if result.returncode >= 0 else 1)
