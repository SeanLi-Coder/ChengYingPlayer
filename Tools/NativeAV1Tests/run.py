"""Bounded native AV1 tests against explicitly verified playback libraries."""
from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = {
    "av1-8bit.ivf": "e3e5875b98ffe84a2cc6dd208552ae2a29027dbac8de8522b1c7a5c399de19e9",
    "av1-10bit.ivf": "86b555a14d98abadc38e18077654c1907a5de8aa445fde21a6f177ac82fa8c7f",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def reference_decoder_available(decoders):
    return re.search(r"^\s*V[A-Z.]{5}\s+libdav1d\s", decoders, re.MULTILINE) is not None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--deps", type=Path, default=ROOT / "deps")
    parser.add_argument("--source-cache", type=Path, default=ROOT / "deps/sources")
    parser.add_argument("--require-hardware", action="store_true")
    parser.add_argument("--sanitizer", choices=("address", "thread"))
    parser.add_argument("--negative-control", choices=("disable-fallback", "drop-current"))
    args = parser.parse_args()
    deps = args.deps.resolve(strict=True)
    work = Path(tempfile.mkdtemp(prefix="native-av1-tests.", dir=ROOT / "build"))
    print(f"Artifacts: {work}", flush=True)
    log = work / "results.log"
    status = 0
    source_paths = [ROOT / "iina/NativePlayback/CYNMediaDecoder.m", ROOT / "iina/NativePlayback/CYNMediaDecoder.h",
                    ROOT / "other/verify_playback_distribution.py", ROOT / "other/playback_ffmpeg_patches.sh",
                    ROOT / "other/build_playback_libraries.sh", ROOT / "other/playback_sources.sh",
                    ROOT / "other/third_party_sources.sh"]
    source_paths += sorted((ROOT / "Tools/NativeAV1Tests").rglob("*.m"))
    source_paths += sorted((ROOT / "Tools/NativeAV1Tests").rglob("*.h"))
    source_paths += sorted((ROOT / "Tools/NativeAV1Tests").rglob("*.py"))
    source_paths += [ROOT / "Tools/NativeAV1Tests/run.sh"]
    source_paths += sorted((ROOT / "other/patches").glob("playback-ffmpeg-*"))
    source_paths += sorted((ROOT / "other/patches").glob("ffmpeg-7.1.5-av1-*.patch"))
    source_paths += sorted((ROOT / "Tools/NativeAV1Tests/fixtures").glob("*"))
    before = {str(p): digest(p) for p in source_paths}
    (work / "source.sha256").write_text("".join(f"{value}  {key}\n" for key, value in before.items()))
    generated = {}

    def run(command, timeout=90):
        command = [str(part) for part in command]
        with log.open("a") as stream:
            stream.write("COMMAND " + shlex.join(command) + "\n")
            stream.flush()
            process = subprocess.Popen(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                result = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                raise RuntimeError("Owned test process exceeded its deadline")
        if result:
            raise subprocess.CalledProcessError(result, command)

    try:
        spec = importlib.util.spec_from_file_location("distribution", ROOT / "other/verify_playback_distribution.py")
        verify = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verify)
        record = deps / "playback-build-record"
        verify.validate_ffmpeg_patches(record, args.source_cache.resolve(strict=True), verify.locked_sources())
        library_locks = verify.checksum_records(record / "library-sha256.txt")
        for name, expected in library_locks.items():
            path = deps / "lib" / name
            verify.require(verify.digest_file(path) == expected, f"Actual library checksum mismatch: {name}")
            before[str(path)] = expected
        verify.validate_configuration(record)
        verify.validate_headers(deps, record)
        before.update({str(path): digest(path) for path in (deps / "include").rglob("*") if path.is_file()})
        provenance = {"deps": str(deps), "library_sha256": library_locks,
                      "scope": "CYN decoder samples, not rendered App or hardware capability inference",
                      "require_hardware": args.require_hardware, "sanitizer": args.sanitizer,
                      "negative_control": args.negative_control}
        (work / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
        ffmpeg = Path(os.environ.get("FFMPEG_BIN", "/opt/homebrew/bin/ffmpeg")).resolve(strict=True)
        before[str(ffmpeg)] = digest(ffmpeg)
        (work / "source.sha256").write_text("".join(f"{value}  {key}\n" for key, value in before.items()))
        reference_probe = subprocess.run([str(ffmpeg), "-hide_banner", "-decoders"], capture_output=True,
                                         text=True, timeout=30, check=True)
        decoder_listing = reference_probe.stdout + reference_probe.stderr
        (work / "reference-decoders.log").write_text(decoder_listing)
        if not reference_decoder_available(decoder_listing):
            raise RuntimeError("Independent AV1 reference CLI requires the libdav1d video decoder. "
                               "Set FFMPEG_BIN to a separate FFmpeg build with libdav1d; "
                               "do not change the production media helper configuration.")
        for name, expected in FIXTURES.items():
            encoded = ROOT / "Tools/NativeAV1Tests/fixtures" / (name + ".base64")
            data = base64.b64decode(b"".join(encoded.read_bytes().split()), validate=True)
            if hashlib.sha256(data).hexdigest() != expected:
                raise RuntimeError("Synthetic AV1 fixture checksum mismatch")
            (work / name).write_bytes(data)
        for depth in ("8", "10"):
            base = [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin"]
            run([*base, "-i", work / f"av1-{depth}bit.ivf", "-f", "lavfi", "-i",
                 "sine=frequency=440:sample_rate=48000:duration=2", "-map", "0:v", "-map", "1:a",
                 "-c:v", "copy", "-c:a", "pcm_f32le", "-shortest", work / f"av1-{depth}.mkv"])
            run([*base, "-c:v", "libdav1d", "-i", work / f"av1-{depth}.mkv", "-an", "-pix_fmt",
                 "nv12" if depth == "8" else "p010le", "-f", "rawvideo", work / f"reference-{depth}.yuv"])
            run([*base, "-stream_loop", "3", "-i", work / f"av1-{depth}bit.ivf", "-f", "lavfi", "-i",
                 "sine=frequency=440:sample_rate=48000:duration=8", "-map", "0:v", "-map", "1:a",
                 "-c:v", "copy", "-c:a", "pcm_f32le", "-shortest", work / f"long-{depth}.mkv"])
            run([*base, "-c:v", "libdav1d", "-i", work / f"long-{depth}.mkv", "-an", "-pix_fmt",
                 "nv12" if depth == "8" else "p010le", "-f", "rawvideo", work / f"long-{depth}.yuv"])
        run([ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-i", work / "av1-8.mkv",
             "-vn", "-c:a", "pcm_f32le", "-f", "f32le", work / "reference.f32"])
        run([ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-i", work / "long-8.mkv",
             "-vn", "-c:a", "pcm_f32le", "-f", "f32le", work / "long.f32"])
        decoder = ROOT / "iina/NativePlayback/CYNMediaDecoder.m"
        if args.negative_control:
            source = decoder.read_text()
            if args.negative_control == "disable-fallback":
                old = "return result < 0 && result != AVERROR(ENOMEM) && result != AVERROR_EXIT &&"
                new = "return NO && result < 0 && result != AVERROR(ENOMEM) && result != AVERROR_EXIT &&"
            else:
                old = "  _av1Replaying = _av1ReplayCount != 0;\n  _av1ReplayIndex = 0;"
                new = "  _av1Replaying = _av1ReplayCount != 0;\n  _av1ReplayIndex = MIN(1, _av1ReplayCount);"
            if source.count(old) != 1:
                raise RuntimeError("Negative-control anchor drifted")
            decoder = work / "CYNMediaDecoder.m"
            decoder.write_text(source.replace(old, new))
            (work / "CYNMediaDecoder.h").write_bytes((ROOT / "iina/NativePlayback/CYNMediaDecoder.h").read_bytes())
        libraries = [deps / "lib" / f"lib{name}.{version}.dylib" for name, version in
                     (("avcodec", 61), ("avformat", 61), ("avutil", 59), ("swresample", 5), ("swscale", 8))]
        flags = [f"-fsanitize={args.sanitizer}"] if args.sanitizer else []
        run(["xcrun", "clang", "-fobjc-arc", "-fmodules", "-std=gnu11", "-g", "-Wall", "-Wextra",
             "-Wno-unused-parameter", *flags, "-I", deps / "include",
             '-DCYN_DECODER_SOURCE="' + str(decoder) + '"', ROOT / "Tools/NativeAV1Tests/main.m", *libraries,
             "-Wl,-rpath," + str(deps / "lib"), "-framework", "Foundation", "-framework", "CoreMedia",
             "-framework", "CoreVideo", "-framework", "AudioToolbox", "-o", work / "native-av1-tests"])
        generated = {str(path): digest(path) for path in work.iterdir()
                     if path.suffix in {".mkv", ".ivf", ".yuv", ".f32", ".m", ".h"}}
        (work / "generated.sha256").write_text("".join(f"{value}  {key}\n" for key, value in generated.items()))
        (work / "source.sha256").write_text("".join(f"{value}  {key}\n" for key, value in before.items()))
        run([work / "native-av1-tests", work, "hardware" if args.require_hardware else "automatic"], timeout=90)
    except Exception as error:
        status = 1
        with log.open("a") as stream:
            stream.write(f"RUNNER ERROR: {type(error).__name__}: {error}\n")
        print(f"FAILED: {error}", flush=True)
    finally:
        changed = [name for name, expected in {**before, **generated}.items()
                   if not Path(name).is_file() or digest(Path(name)) != expected]
        (work / "hash-validation.json").write_text(json.dumps({"changed": changed}, indent=2) + "\n")
        if changed:
            status = 1
            print("Source/library/generated input hashes changed; run is invalid", flush=True)
        print(log.read_text()[-9000:] if log.exists() else "No process log", flush=True)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
