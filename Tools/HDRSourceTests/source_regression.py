"""Build real mpv image functions against pinned libplacebo and bundled FFmpeg."""

from __future__ import annotations

import argparse
import subprocess
import tempfile
from pathlib import Path


def block(source: str, signature: str, *, declaration: bool = False) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    offset = opening + 1
    # These pinned declarations/functions have no braces in strings or comments.
    while depth:
        depth += (source[offset] == "{") - (source[offset] == "}")
        offset += 1
    return source[start:offset + int(declaration)]


def format_boundary(source: Path, patched: bool) -> str:
    text = (source / "video/filter/vf_format.c").read_text()
    process = block(text, "static void vf_format_process(")
    if patched:
        convert, passthrough = process.split("if (!priv->opts->convert)", 1)
        for code, target in ((convert, "par"), (passthrough, "img->params")):
            assert code.index(f"mp_image_params_restore_dovi_mapping(&{target})") < code.index(
                f"set_params(priv->opts, &{target},"
            ), "Fallback must precede explicit format overrides"
        renderer = (source / "video/out/gpu/video.c").read_text()
        init = block(renderer, "static void init_video(")
        assert init.index("mp_image_params_restore_dovi_mapping(&p->image_params)") < init.index(
            "mp_image_params_guess_csp(&p->image_params)"
        ), "GL fallback must precede colorspace inference"
        assert "restore_dovi_mapping(&p->real_image_params)" not in renderer

    return "\n".join((
        (
            '#include <assert.h>\n#include <limits.h>\n#include <libavutil/rational.h>\n'
            '#include "video/mp_image.h"'
        ),
        block(text, "struct vf_format_opts {", declaration=True),
        block(text, "static void set_params("),
        r'''
void test_format_filter(void)
{
    struct mp_image_params params = {
        .imgfmt = IMGFMT_420P, .w = 64, .h = 64, .p_w = 1, .p_h = 1,
        .repr.sys = PL_COLOR_SYSTEM_BT_2020_NC,
        .color = {.transfer = PL_COLOR_TRC_HLG, .primaries = PL_COLOR_PRIM_BT_2020,
                  .hdr.max_luma = 1000},
        .light = MP_CSP_LIGHT_SCENE_HLG,
    };
    struct vf_format_opts opts = {.gamma = PL_COLOR_TRC_PQ, .rotate = -1};
    set_params(&opts, &params, false);
    assert(params.color.transfer == PL_COLOR_TRC_PQ);
    assert(params.color.hdr.max_luma == 0 && params.light == MP_CSP_LIGHT_AUTO);
    mp_image_params_guess_csp(&params);
    assert(params.light == MP_CSP_LIGHT_DISPLAY);
    opts.gamma = PL_COLOR_TRC_HLG;
    set_params(&opts, &params, false);
    assert(params.color.hdr.max_luma == 0 && params.light == MP_CSP_LIGHT_AUTO);
    mp_image_params_guess_csp(&params);
    assert(params.color.hdr.max_luma == 1000 && params.light == MP_CSP_LIGHT_SCENE_HLG);
    opts.gamma = PL_COLOR_TRC_BT_1886;
    set_params(&opts, &params, false);
    mp_image_params_guess_csp(&params);
    assert(params.color.transfer == PL_COLOR_TRC_BT_1886);
    assert(params.light == MP_CSP_LIGHT_DISPLAY);
    puts("PASS: Actual format-filter transfer overrides refresh HDR and light inference");
}
''',
    ))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("placebo_prefix", type=Path)
    parser.add_argument("dependencies", type=Path)
    parser.add_argument("--expect-regression", action="store_true")
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    placebo = args.placebo_prefix.resolve(strict=True)
    deps = args.dependencies.resolve(strict=True)
    patched = not args.expect_regression
    boundary = '#include <stdio.h>\n' + format_boundary(source, patched)
    sources = [
        "video/mp_image.c", "video/img_format.c", "video/fmt-conversion.c",
        "video/csputils.c", "common/common.c", "ta/ta.c", "ta/ta_talloc.c", "ta/ta_utils.c",
    ]
    with tempfile.TemporaryDirectory(prefix="chengying-hdr-image-") as directory:
        test_dir = Path(directory)
        # Use the playback build's actual configuration; no alternate feature set.
        (test_dir / "config.h").write_bytes(
            (deps / "playback-build-record/mpv-config.h").read_bytes()
        )
        binary = test_dir / "HDRSourceTests"
        subprocess.run(
            [
                "xcrun", "clang", "-std=c11", "-D_GNU_SOURCE",
                f"-DHAVE_DOVI_FALLBACK={int(patched)}", "-O1", "-g",
                "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                "-Wno-deprecated-declarations", "-Wno-switch",
                "-ffunction-sections", "-fdata-sections",
                "-I", str(test_dir), "-I", str(source),
                "-I", str(placebo / "include"), "-I", str(deps / "include"),
                str(Path(__file__).with_name("main.c")),
                *[str(source / filename) for filename in sources],
                "-x", "c", "-", "-x", "none",
                str(placebo / "lib/libplacebo.a"), str(deps / "lib/libavutil.59.dylib"),
                "-Wl,-dead_strip", f"-Wl,-rpath,{deps / 'lib'}", "-o", str(binary),
            ],
            input=boundary, text=True, check=True, timeout=90,
        )
        result = subprocess.run(
            [str(binary)], capture_output=True, text=True, timeout=30, check=False
        )
        if args.expect_regression:
            expected = "FAIL: Fallback restores the base-layer transfer function"
            if result.returncode != 1 or result.stderr.strip() != expected:
                raise AssertionError(f"Original source did not reproduce the regression: {result}")
            print("PASS: Original pinned mpv/libplacebo reproduces the Dolby Vision HLG regression")
        else:
            print(result.stdout, end="")
            if result.returncode:
                raise AssertionError(result.stderr)


if __name__ == "__main__":
    main()
