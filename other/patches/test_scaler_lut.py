"""Verify the pinned mpv LUT-padding backport without creating an app or GL context."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[2]
PATCHES = Path(__file__).resolve().parent
MPV = "mpv-0.38.0"
VIDEO = f"{MPV}/video/out/gpu/video.c"
PREVIOUS_VIDEO_SHA256 = "da5f01f741c66f6154b33b4dc4ce1ff7e0e20cf474f3880ae9b62f842689ae07"
ARCHIVE_SHA256 = "86d9ef40b6058732f67b46d0bbda24a074fae860b3eaae05bab3145041303066"

HARNESS = r'''
#include <stdio.h>
#include <stdlib.h>

static void apply_padding(float *weights, int size, int num_components, int stride,
                          int lut_size)
{
    (void) weights; (void) size; (void) num_components; (void) stride; (void) lut_size;
    /* INSERT_PADDING_BLOCK */
}

static int check_lut(struct filter_kernel filter, float poison, bool expect_fixed)
{
    const int size = filter.size;
    const int num_components = size > 2 ? 4 : size;
    const int stride = ((size + num_components - 1) / num_components) * num_components;
    const int lut_size = 256;
    const int count = lut_size * stride;
    float *allocation = malloc((count + 2) * sizeof(float));
    float *before = malloc(count * sizeof(float));
    assert(allocation && before);
    float *weights = allocation + 1;
    allocation[0] = allocation[count + 1] = 123456.0f;
    for (int n = 0; n < count; n++) weights[n] = poison;
    mp_compute_lut(&filter, lut_size, stride, weights);
    memcpy(before, weights, count * sizeof(float));
    apply_padding(weights, size, num_components, stride, lut_size);
    int padding_count = 0;
    for (int row = 0; row < lut_size; row++) {
        for (int i = 0; i < size; i++) {
            int index = row * stride + i;
            assert(isfinite(weights[index]));
            assert(memcmp(&before[index], &weights[index], sizeof(float)) == 0);
        }
        for (int i = size; i < stride; i++) {
            int index = row * stride + i;
            padding_count++;
            assert(!isfinite(before[index]));
            if (expect_fixed) {
                assert(isfinite(weights[index]));
                assert(weights[index] == weights[index - num_components]);
            } else {
                assert(!isfinite(weights[index]));
            }
        }
    }
    assert(allocation[0] == 123456.0f && allocation[count + 1] == 123456.0f);
    free(before);
    free(allocation);
    return padding_count;
}

int main(int argc, char **argv)
{
    const bool fixed = argc == 2 && strcmp(argv[1], "fixed") == 0;
    const int sizes[] = {2, 4, 6, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60, 64, 0};
    const float poisons[] = {NAN, INFINITY, -INFINITY};
    const double scales[] = {0.5, 1.0, 2.0, 8.0, 128.0};
    struct filter_kernel lanczos = *mp_find_filter_kernel("lanczos");
    lanczos.w = *mp_find_filter_window(lanczos.window);
    assert(mp_init_filter(&lanczos, sizes, 1.0) && lanczos.size == 6);
    assert(check_lut(lanczos, NAN, fixed) == 512);
    if (!fixed) {
        puts("PASS: Unpatched six-tap LUT retains 512 poisoned padding floats");
        return 0;
    }
    int cases = 0;
    for (const struct filter_kernel *kernel = mp_filter_kernels; kernel->f.name; kernel++) {
        for (unsigned s = 0; s < sizeof(scales) / sizeof(scales[0]); s++) {
            for (unsigned p = 0; p < sizeof(poisons) / sizeof(poisons[0]); p++) {
                struct filter_kernel filter = *kernel;
                const struct filter_window *window = mp_find_filter_window(filter.window);
                if (window) filter.w = *window;
                (void)mp_init_filter(&filter, sizes, scales[s]);
                check_lut(filter, poisons[p], true);
                cases++;
            }
        }
    }
    // Exercise each supported separable size independently of kernel selection.
    for (int i = 0; sizes[i]; i++) {
        for (unsigned p = 0; p < sizeof(poisons) / sizeof(poisons[0]); p++) {
            struct filter_kernel filter = lanczos;
            filter.size = sizes[i];
            check_lut(filter, poisons[p], true);
            cases++;
        }
    }
    printf("PASS: %d kernel/size/poison cases; coefficients and allocation guards unchanged\n", cases);
    return 0;
}
'''


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def padding_block(source: str) -> str:
    marker = "mp_compute_lut(scaler->kernel, lut_size, stride, weights);"
    assert source.count(marker) == 1
    start = source.index(marker) + len(marker)
    end = source.index("bool use_1d =", start)
    return source[start:end].strip()


def extract_sources(archive: Path, output: Path) -> None:
    names = {line.split()[1] for line in (PATCHES / "playback-before-sha256.txt").read_text().splitlines()}
    names.update(f"{MPV}/{name}" for name in (
        "video/out/filter_kernels.c", "video/out/filter_kernels.h", "common/common.h"))
    with tarfile.open(archive, "r:gz") as contents:
        for name in sorted(names):
            member = contents.getmember(name)
            assert member.isfile() and 0 < member.size < 5_000_000
            stream = contents.extractfile(member)
            assert stream is not None
            with stream:
                data = stream.read()
            target = output / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-cache", type=Path, default=ROOT / "deps/sources")
    args = parser.parse_args()
    archive = args.source_cache / f"{MPV}.tar.gz"
    assert sha(archive.read_bytes()) == ARCHIVE_SHA256, "Pinned source archive mismatch"
    rows = [line.split("\t") for line in (PATCHES / "playback-patches.tsv").read_text().splitlines()]
    assert len(rows) == 5 and rows[-1][0] == "mpv-scaler-lut-padding"
    with tempfile.TemporaryDirectory(prefix="chengying-lut-source-") as temporary:
        work = Path(temporary)
        original = work / "original"
        source = work / "source"
        extract_sources(archive, original)
        shutil.copytree(original, source)
        for index, (_name, component, filename, _origin, expected) in enumerate(rows):
            patch = PATCHES / filename
            assert sha(patch.read_bytes()) == expected, "Patch bytes differ from lock"
            if index == len(rows) - 1:
                before = (source / VIDEO).read_bytes()
                assert sha(before) == PREVIOUS_VIDEO_SHA256, "Previous patch chain changed"
                assert padding_block(before.decode()) == "", "Negative control already patched"
            subprocess.run(["patch", "--batch", "--forward", "--fuzz=0", "-d", str(source / component),
                            "-p1", "-i", str(patch)], check=True, timeout=15)
        after = (source / VIDEO).read_bytes()
        block = padding_block(after.decode())
        assert "row[i] = row[i - num_components];" in block
        subprocess.run(["shasum", "-a", "256", "-c", str(PATCHES / "playback-after-sha256.txt")],
                       cwd=source, check=True, timeout=15)
        # Independently exercise the production patch applier and build records.
        subprocess.run(["/bin/bash", "-c", 'source "$1"\napply_playback_patches "$2" "$3"',
                        "lut-test", str(ROOT / "other/playback_patches.sh"),
                        str(original), str(work / "record")], check=True, timeout=30)
        assert (original / VIDEO).read_bytes() == after
        print(f"PASS: Ordered patch chain; video.c {sha(before)} -> {sha(after)}")

        kernel = (source / MPV / "video/out/filter_kernels.c").read_text()
        header = (source / MPV / "video/out/filter_kernels.h").read_text()
        common = (source / MPV / "common/common.h").read_text()
        # Preserve the actual kernel implementation and the sole project macro
        # it uses; avoid pulling unrelated player dependencies into this test.
        macro = re.search(r"^#define MPMAX\(a, b\).*$", common, re.MULTILINE)
        assert macro is not None
        assert kernel.count('#include "filter_kernels.h"') == 1
        assert kernel.count('#include "common/common.h"') == 1
        kernel = kernel.replace('#include "filter_kernels.h"', header)
        kernel = kernel.replace('#include "common/common.h"', macro.group(0))
        for label, padding in (("original", ""), ("fixed", block)):
            program = kernel + HARNESS.replace("/* INSERT_PADDING_BLOCK */", padding)
            binary = work / f"lut-{label}"
            subprocess.run(["xcrun", "clang", "-std=c11", "-D_DARWIN_C_SOURCE", "-O1", "-g",
                            "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                            "-x", "c", "-", "-o", str(binary)],
                           input=program, text=True, check=True, timeout=60)
            subprocess.run([str(binary), label], check=True, timeout=30)
    print("PASS: Source-only LUT regression; no app, GL context or dependency replacement")


if __name__ == "__main__":
    main()
