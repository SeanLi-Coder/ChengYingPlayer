#!/usr/bin/env python3
"""Build/run the synthetic Apple software-GL scaler-LUT causal regression."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PATCH = ROOT / "other/patches/mpv-0.38.0-scaler-lut-padding.patch"


def extract_padding_loop(patch: Path) -> str:
    """Only compile the isolated added loop from the actual one-file backport."""
    data = patch.read_bytes()
    if len(data) > 64 * 1024:
        raise ValueError("The scaler-LUT patch exceeds the source-size bound")
    text = data.decode("utf-8")
    targets = re.findall(r"^\+\+\+ (.+)$", text, re.MULTILINE)
    if targets != ["b/video/out/gpu/video.c"]:
        raise ValueError("Expected a patch changing only video/out/gpu/video.c")
    if len(re.findall(r"^@@ ", text, re.MULTILINE)) != 1:
        raise ValueError("Expected one isolated scaler-LUT patch hunk")
    if any(line.startswith("-") and not line.startswith("--- ") for line in text.splitlines()):
        raise ValueError("The padding-only patch must not remove existing source")
    added = "\n".join(
        line[1:] for line in text.splitlines()
        if line.startswith("+") and not line.startswith("+++ ")
    ).strip()
    # Fail closed if the upstream patch grows beyond the reviewed isolated loop.
    structure = (
        r"for\s*\(int n\s*=\s*0;\s*n\s*<\s*lut_size;\s*n\+\+\)\s*\{\s*"
        r"float \*row\s*=\s*weights\s*\+\s*n\s*\*\s*stride;\s*"
        r"for\s*\(int i\s*=\s*size;\s*i\s*<\s*stride;\s*i\+\+\)\s*"
        r"row\[i\]\s*=\s*row\[i\s*-\s*num_components\];\s*\}"
    )
    if not re.fullmatch(structure, added):
        raise ValueError("The patch additions are not the reviewed upstream padding loop")
    return added + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compile-only", action="store_true", help="Do not create a GL context or execute the binary")
    parser.add_argument("--patch", type=Path, default=DEFAULT_PATCH, help="Actual reviewed scaler-LUT backport patch")
    args = parser.parse_args()
    if sys.platform != "darwin":
        print("FAIL: The CGL causal regression requires macOS", file=sys.stderr)
        return 1
    compiler = shutil.which("clang")
    if not compiler:
        print("FAIL: clang is unavailable", file=sys.stderr)
        return 1
    try:
        loop = extract_padding_loop(args.patch)
        patch_digest = hashlib.sha256(args.patch.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory(prefix="chengying-scaler-lut-") as directory:
            workspace = Path(directory)
            header = workspace / "scaler_lut_patch.h"
            header.write_text(
                "// Generated from the reviewed repository patch.\n"
                "static void apply_repository_padding_patch(float *weights, int lut_size,\n"
                "                                           int stride, int size, int num_components) {\n"
                + loop + "}\n",
                encoding="utf-8",
            )
            executable = workspace / "scaler-lut-check"
            command = [
                compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-pedantic",
                "-I", os.fspath(workspace), os.fspath(Path(__file__).with_name("main.c")),
                "-framework", "OpenGL", "-o", os.fspath(executable),
            ]
            subprocess.run(command, check=True, timeout=90)
            print(json.dumps({"type": "build", "compiled": True,
                              "patch_sha256": patch_digest, "gl_executed": False}), flush=True)
            if args.compile_only:
                print("COMPILED: No OpenGL context was created; this is not a rendering pass.")
                return 0
            result = subprocess.run([os.fspath(executable)], check=False, timeout=30)
            if result.returncode == 77:
                print("NOT_APPLICABLE: Poison did not corrupt a valid coefficient on this renderer; "
                      "the causal regression is not counted as passed.")
            return result.returncode if result.returncode >= 0 else 1
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"FAIL: Scaler-LUT regression could not complete: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
