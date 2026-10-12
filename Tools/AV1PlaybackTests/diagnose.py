#!/usr/bin/env python3
"""Compare the pinned playback backend with unmodified official FFmpeg locally.

This is an additional diagnostic, not a replacement or waiver for run.py.
Every case runs in its own bounded process, so an earlier failure cannot hide
the remaining sizes, bit depths, or the independent upstream decoder result.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
FIXTURES = (
    ("av1-8bit.ivf", "fixtures", 192, 108, 8, 0,
     "e3e5875b98ffe84a2cc6dd208552ae2a29027dbac8de8522b1c7a5c399de19e9"),
    ("av1-10bit.ivf", "fixtures", 192, 108, 10, 0,
     "86b555a14d98abadc38e18077654c1907a5de8aa445fde21a6f177ac82fa8c7f"),
    ("av1-1080p-8bit.ivf", "diagnostic-fixtures", 1920, 1080, 8, 8,
     "38709c93e231257b0b9c86372432468029ca2322d786764cb356542ec18e0fe1"),
    ("av1-1080p-10bit.ivf", "diagnostic-fixtures", 1920, 1080, 10, 8,
     "6ae03df05168949d9b7066620bb7db0ba05ddd88768bdb0903af607e3de36140"),
)


class Matrix:
    def __init__(self, report):
        self.report = report
        self.deadline = time.monotonic() + 660
        self.results = []
        self.details = {"schema": 1, "scope": "synthetic headless AV1 decoder comparison",
                        "results": self.results,
                        "limit": "Different dimensions also have different AV1 level/header values. "
                                 "A size-dependent result alone does not establish the root cause."}

    def save(self):
        (self.report / "summary.json").write_text(
            json.dumps(self.details, indent=2) + "\n", encoding="utf-8")

    def run(self, name, command, *, timeout, cwd=None):
        result = {"name": name, "command": [str(x) for x in command],
                  "log": name + ".log", "passed": False, "timed_out": False}
        self.results.append(result)
        started = time.monotonic()
        remaining = min(timeout, self.deadline - started)
        if remaining <= 0:
            result["error"] = "The overall diagnostic deadline expired"
            (self.report / result["log"]).write_text(result["error"] + "\n", encoding="utf-8")
            self.save()
            return result
        try:
            with (self.report / result["log"]).open("wb") as output:
                process = subprocess.Popen(result["command"], cwd=cwd, stdout=output,
                                           stderr=subprocess.STDOUT, start_new_session=True,
                                           stdin=subprocess.DEVNULL)
                try:
                    result["returncode"] = process.wait(timeout=remaining)
                except subprocess.TimeoutExpired:
                    result["timed_out"] = True
                    terminate_owned_group(process)
                    result["returncode"] = process.returncode
                except BaseException:
                    terminate_owned_group(process)
                    raise
                result["passed"] = result["returncode"] == 0 and not result["timed_out"]
        except (OSError, subprocess.SubprocessError) as error:
            result["error"] = str(error)
        result["elapsed_seconds"] = round(time.monotonic() - started, 3)
        self.save()
        print(f"{'PASS' if result['passed'] else 'FAIL'}: {name} (see {result['log']})", flush=True)
        return result


def terminate_owned_group(process):
    # The shell can exit before its compiler children; always kill any surviving
    # members of this newly created group, even after the group leader exits.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)


def fixture_files(work):
    metadata = []
    for name, directory, width, height, depth, level, digest in FIXTURES:
        encoded = (HERE / directory / (name + ".base64")).read_bytes()
        contents = base64.b64decode(b"".join(encoded.split()), validate=True)
        if hashlib.sha256(contents).hexdigest() != digest:
            raise RuntimeError("Synthetic AV1 fixture checksum mismatch: " + name)
        (work / name).write_bytes(contents)
        metadata.append({"name": name, "sha256": digest, "width": width, "height": height,
                         "depth": depth, "level_index": level, "frames": 24, "rate": "12/1"})
    return metadata


def candidate_source(work, width, height):
    original = (HERE / "main.c").read_text(encoding="utf-8")
    source = original
    if (width, height) != (192, 108):
        replacements = {
            "frame->width == 192 && frame->height == 108":
                f"frame->width == {width} && frame->height == {height}",
            "width == 192 && height == 108": f"width == {width} && height == {height}",
            "at 192x108": f"at {width}x{height}",
        }
        for before, after in replacements.items():
            if source.count(before) != 1:
                raise RuntimeError("The strict candidate test changed; review diagnostic dimension adaptation")
            source = source.replace(before, after)
    source = "#define main original_suite_main\n" + source + r'''
#undef main
int main(int argc, char **argv) {
    require(argc == 3, "One synthetic fixture and bit depth are required");
    int depth = atoi(argv[2]);
    require(depth == 8 || depth == 10, "Supported synthetic bit depth");
    check_backend();
    bool hardware = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1);
    printf("INFO: AV1 VideoToolbox hardware capability=%s\n", hardware ? "yes" : "no");
    decode_fixture(argv[1], depth);
    play_fixture(argv[1], depth, "no", hardware);
    play_fixture(argv[1], depth, "videotoolbox-copy", hardware);
    if (!hardware)
        puts("LIMIT: Candidate passed software fallback only; upstream forced hardware remains mandatory.");
    return 0;
}
'''
    target = work / f"candidate-{width}x{height}.c"
    target.write_text(source, encoding="utf-8")
    return target, hashlib.sha256(original.encode()).hexdigest()


def run_matrix(args, matrix, work):
    deps = args.deps.resolve(strict=True)
    matrix.details["fixtures"] = fixture_files(work)
    verified = matrix.run("candidate-library-checksums", ["shasum", "-a", "256", "-c",
               deps / "playback-build-record/library-sha256.txt"], timeout=30, cwd=deps / "lib")
    if not verified["passed"]:
        matrix.details["setup_error"] = "Refusing to execute libraries with an invalid build record"
        matrix.save()
        return
    executables = {}
    for width, height in ((192, 108), (1920, 1080)):
        source, digest = candidate_source(work, width, height)
        matrix.details["strict_main_sha256"] = digest
        executable = source.with_suffix("")
        compiled = matrix.run(f"candidate-build-{width}x{height}",
            ["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
             "-I", deps / "include", source, deps / "lib/libmpv.2.dylib",
             deps / "lib/libavcodec.61.dylib", deps / "lib/libavformat.61.dylib",
             deps / "lib/libavutil.59.dylib", "-framework", "VideoToolbox",
             "-framework", "CoreMedia", "-framework", "CoreFoundation",
             "-Wl,-rpath," + str(deps / "lib"), "-o", executable], timeout=90)
        if compiled["passed"]:
            executables[(width, height)] = executable
    reference = work / "reference"
    built = matrix.run("reference-build", ["/bin/bash", HERE / "build_reference.sh",
        "--output", reference, "--source-cache", args.source_cache.resolve()], timeout=360)
    for name in ("metadata.txt", "version.txt", "config.h", "config_components.h",
                 "configure.log", "build.log", "dependencies.txt", "null-output-control.log",
                 "ffmpeg.sha256", "ffbuild-config.log"):
        origin = reference / name
        if origin.is_file():
            # Keep the build subprocess transcript separate from its make log.
            shutil.copyfile(origin, matrix.report / ("reference-artifact-" + name))
    cli = reference / "bin/ffmpeg"
    for name, _, width, height, depth, _, _ in FIXTURES:
        stem = Path(name).stem
        executable = executables.get((width, height))
        if executable:
            result = matrix.run("candidate-" + stem, [executable, work / name, str(depth)], timeout=60)
            log = (matrix.report / result["log"]).read_text(encoding="utf-8", errors="replace")
            result["software_decoded_frames"] = 24 if "decoded all 24 AV1" in log else 0
            result["hardware_capability"] = re.findall(r"hardware capability=(yes|no)", log)
            result["active_decoder_paths"] = re.findall(r"requested=(\S+) active=(\S+)", log)
        else:
            matrix.results.append({"name": "candidate-" + stem, "passed": False,
                                   "error": "Candidate comparison executable did not build"})
        if built["passed"] and cli.is_file():
            pixel_format = "nv12" if depth == 8 else "p010le"
            # Native AV1 plus hwdownload forbids a silent software fallback from
            # being accepted as a successful upstream VideoToolbox decode.
            result = matrix.run("reference-" + stem,
                [cli, "-hide_banner", "-loglevel", "debug", "-nostdin", "-xerror",
                 "-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox",
                 "-c:v", "av1", "-i", work / name, "-map", "0:v:0", "-an", "-sn", "-dn",
                 "-vf", "hwdownload,format=" + pixel_format, "-frames:v", "24",
                 "-progress", "pipe:1", "-f", "null", "-"], timeout=40)
            log = (matrix.report / result["log"]).read_text(encoding="utf-8", errors="replace")
            frames = re.findall(r"^frame=\s*(\d+)\s*$", log, re.M)
            result["decoded_frames"] = int(frames[-1]) if frames else 0
            result["progress_ended"] = bool(re.search(r"^progress=end\s*$", log, re.M))
            result["passed"] = result["passed"] and result["decoded_frames"] == 24 and result["progress_ended"]
            if not result["passed"]:
                print("FAIL: Upstream native VideoToolbox must decode all 24 hardware frames: " + stem,
                      flush=True)
        else:
            matrix.results.append({"name": "reference-" + stem, "passed": False,
                                   "error": "Official reference executable did not build"})
        matrix.save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deps", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True,
                        help="New directory for persistent logs and summary.json; never overwritten")
    parser.add_argument("--source-cache", type=Path, default=ROOT / "deps/sources")
    args = parser.parse_args()
    report = args.report.absolute()
    report.mkdir(parents=True, exist_ok=False)
    matrix = Matrix(report)
    try:
        with tempfile.TemporaryDirectory(prefix="chengying-av1-matrix-") as temporary:
            run_matrix(args, matrix, Path(temporary))
    except Exception as error:
        matrix.results.append({"name": "diagnostic-setup", "passed": False, "error": str(error)})
    matrix.details["passed"] = bool(matrix.results) and all(x["passed"] for x in matrix.results)
    matrix.save()
    for result in matrix.results:
        frames = result.get("decoded_frames", result.get("software_decoded_frames", "n/a"))
        print(f"RESULT: {result['name']} {'PASS' if result['passed'] else 'FAIL'} "
              f"exit={result.get('returncode', 'not-run')} frames={frames}")
    print(f"Diagnostic result: {'PASS' if matrix.details['passed'] else 'FAIL'}; {report / 'summary.json'}")
    return 0 if matrix.details["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
