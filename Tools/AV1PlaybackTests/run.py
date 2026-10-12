#!/usr/bin/env python3
"""Exercise the actual candidate decoder libraries using bounded synthetic media."""
import base64
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = {
    "av1-8bit.ivf": "e3e5875b98ffe84a2cc6dd208552ae2a29027dbac8de8522b1c7a5c399de19e9",
    "av1-10bit.ivf": "86b555a14d98abadc38e18077654c1907a5de8aa445fde21a6f177ac82fa8c7f",
}


def run(command, *, timeout=90, cwd=None):
    subprocess.run([str(part) for part in command], check=True, timeout=timeout, cwd=cwd)


def main():
    deps = Path(sys.argv[1]).resolve(strict=True)
    record = deps / "playback-build-record"
    run([sys.executable, ROOT / "Tools/AV1PlaybackTests/test_patch_application.py"])
    run(["shasum", "-a", "256", "-c", record / "library-sha256.txt"], cwd=deps / "lib")
    source = (ROOT / "iina/MPVController.swift").read_text()
    match = re.search(r"  static func compiledAV1VideoToolboxSupport\(\) -> Bool \{.*?\n  \}", source, re.S)
    if not match:
        raise RuntimeError("Production AV1 capability helper was not found")
    # Keep both independent gates in the production whitelist, not just the test.
    start = source.index("  private func adjustCodecWhiteList()")
    end = source.index("\n  }", start)
    whitelist = source[start:end]
    if "HardwareDecodeCapabilities.shared.isSupported(codecType)" not in whitelist or \
            "codecType == kCMVideoCodecType_AV1 && !Self.compiledAV1VideoToolboxSupport()" not in whitelist:
        raise RuntimeError("Production AV1 hardware/backend dual gate is missing")
    with tempfile.TemporaryDirectory(prefix="chengying-av1-playback-") as temporary:
        work = Path(temporary)
        for name, digest in FIXTURES.items():
            encoded = (ROOT / "Tools/AV1PlaybackTests/fixtures" / (name + ".base64")).read_bytes()
            decoded = base64.b64decode(b"".join(encoded.split()), validate=True)
            if hashlib.sha256(decoded).hexdigest() != digest:
                raise RuntimeError("Synthetic AV1 fixture checksum mismatch")
            (work / name).write_bytes(decoded)
        # Compile the actual Swift helper against the same pinned C API as the app.
        (work / "Bridge.h").write_text("#include <libavcodec/avcodec.h>\n")
        (work / "main.swift").write_text(
            "enum ActualBackend {\n" + match.group(0) + "\n}\n" +
            'precondition(ActualBackend.compiledAV1VideoToolboxSupport(), "AV1 VideoToolbox backend missing")\n' +
            'print("PASS: Production Swift AV1 backend capability gate")\n')
        run(["xcrun", "swiftc", "-I", deps / "include", "-import-objc-header", work / "Bridge.h",
             work / "main.swift", deps / "lib/libavcodec.61.dylib", deps / "lib/libavutil.59.dylib",
             "-Xlinker", "-rpath", "-Xlinker", deps / "lib", "-o", work / "AV1GateTests"])
        run([work / "AV1GateTests"], timeout=15)
        baseline = os.environ.get("AV1_BASELINE_DEPS")
        if baseline:
            baseline = Path(baseline).resolve(strict=True)
            (work / "main.swift").write_text(
                "enum ActualBackend {\n" + match.group(0) + "\n}\n" +
                'precondition(!ActualBackend.compiledAV1VideoToolboxSupport(), "Baseline unexpectedly supports AV1 VideoToolbox")\n' +
                'print("PASS: Production Swift gate rejects the actual unpatched baseline library")\n')
            run(["xcrun", "swiftc", "-I", baseline / "include", "-import-objc-header", work / "Bridge.h",
                 work / "main.swift", baseline / "lib/libavcodec.61.dylib", baseline / "lib/libavutil.59.dylib",
                 "-Xlinker", "-rpath", "-Xlinker", baseline / "lib", "-o", work / "AV1BaselineGateTests"])
            run([work / "AV1BaselineGateTests"], timeout=15)
        run(["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
             "-I", deps / "include", ROOT / "Tools/AV1PlaybackTests/main.c",
             deps / "lib/libmpv.2.dylib", deps / "lib/libavcodec.61.dylib",
             deps / "lib/libavformat.61.dylib", deps / "lib/libavutil.59.dylib",
             "-framework", "VideoToolbox", "-framework", "CoreMedia", "-framework", "CoreFoundation",
             "-Wl,-rpath," + str(deps / "lib"), "-o", work / "AV1PlaybackTests"])
        run([work / "AV1PlaybackTests", *[work / name for name in FIXTURES]], timeout=120)


if __name__ == "__main__":
    main()
