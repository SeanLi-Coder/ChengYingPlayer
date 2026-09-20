"""Compile the actual mpv refresh/seek functions with controlled state boundaries.

This complements the real-libmpv regression; it does not replace decoding or
prove that a distributed dylib contains the patched source.
"""

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
    # These pinned functions contain no string literals or comments with braces.
    while depth:
        if source[offset] == "{":
            depth += 1
        elif source[offset] == "}":
            depth -= 1
        offset += 1
    if declaration:
        if source[offset] != ";":
            raise ValueError(f"Unexpected declaration terminator for {signature}")
        offset += 1
    return source[start:offset]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Extracted mpv source root")
    parser.add_argument("--expect-regression", action="store_true")
    args = parser.parse_args()
    root = args.source.resolve(strict=True)
    header = (root / "player/core.h").read_text()
    declarations = "\n".join(
        block(header, declaration, declaration=True)
        for declaration in (
            "enum stop_play_reason {", "enum seek_type {", "enum seek_precision {",
            "enum seek_flags {", "struct seek_params {", "enum playback_status {",
        )
    )
    functions = []
    for filename, name in (
        ("playloop.c", "queue_seek"), ("misc.c", "issue_refresh_seek"),
        ("video.c", "mp_force_video_refresh"),
    ):
        source = (root / "player" / filename).read_text()
        functions.append(block(source, f"void {name}("))

    boundary = r'''
struct MPOpts { bool pause; };
struct vo_chain { int unused; };
struct MPContext {
    struct MPOpts *opts;
    struct vo_chain *vo_chain;
    enum stop_play_reason stop_play;
    enum playback_status video_status;
    struct seek_params seek, current_seek;
    double time_frame, playback_pts;
    unsigned wakeups;
};
static void mp_wakeup_core(struct MPContext *ctx) { ctx->wakeups++; }
static double get_current_time(struct MPContext *ctx) { return ctx->playback_pts; }
#define MPMAX(a, b) ((a) > (b) ? (a) : (b))
#define MP_ASSERT_UNREACHABLE() abort()
'''
    cases = r'''
static void check(bool ok, const char *message)
{
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

int main(void)
{
    struct MPOpts opts = {0};
    struct vo_chain video = {0};
    struct MPContext ctx = {.opts = &opts, .vo_chain = &video,
        .video_status = STATUS_EOF, .stop_play = AT_END_OF_FILE, .playback_pts = 0.6};
    // This is the exact rotation refresh path invoked from an on_unload hook.
    mp_force_video_refresh(&ctx);
    check(ctx.stop_play == AT_END_OF_FILE, "Rotation refresh preserves EOF during teardown");
    check(ctx.seek.type == MPSEEK_ABSOLUTE && ctx.seek.amount == 0.6 &&
          ctx.seek.exact == MPSEEK_VERY_EXACT && ctx.wakeups == 1,
          "EOF refresh remains queued with its precise last-frame target");

    for (enum stop_play_reason state = KEEP_PLAYING; state <= PT_ERROR; state++) {
        ctx.stop_play = state;
        ctx.seek = (struct seek_params){0};
        queue_seek(&ctx, MPSEEK_ABSOLUTE, 1.25, MPSEEK_EXACT, MPSEEK_FLAG_DELAY);
        check(ctx.stop_play == state, "Queueing a seek never changes the playback exit reason");
        queue_seek(&ctx, MPSEEK_RELATIVE, -0.25, MPSEEK_VERY_EXACT, MPSEEK_FLAG_NOFLUSH);
        check(ctx.seek.type == MPSEEK_ABSOLUTE && ctx.seek.amount == 1 &&
              ctx.seek.exact == MPSEEK_VERY_EXACT &&
              ctx.seek.flags == (MPSEEK_FLAG_DELAY | MPSEEK_FLAG_NOFLUSH),
              "Coalesced relative seeking preserves target, precision and flags");
        queue_seek(&ctx, MPSEEK_NONE, 0, MPSEEK_DEFAULT, 0);
        check(ctx.seek.type == MPSEEK_NONE && ctx.seek.flags == 0 && ctx.stop_play == state,
              "Cancelling pending seeking preserves EOF and other exit reasons");
    }
    ctx.stop_play = KEEP_PLAYING;
    ctx.video_status = STATUS_PLAYING;
    ctx.wakeups = 0;
    mp_force_video_refresh(&ctx);
    check(ctx.seek.type == MPSEEK_NONE && ctx.wakeups == 0,
          "Ordinary playing rotation waits for the next decoded frame");
    opts.pause = true;
    mp_force_video_refresh(&ctx);
    check(ctx.seek.type == MPSEEK_ABSOLUTE && ctx.stop_play == KEEP_PLAYING,
          "Paused rotation still queues a refresh seek");
    ctx.current_seek = (struct seek_params){.type = MPSEEK_ABSOLUTE, .amount = 2,
        .exact = MPSEEK_VERY_EXACT};
    ctx.seek = (struct seek_params){0};
    mp_force_video_refresh(&ctx);
    check(ctx.seek.amount == 2, "Rotation retains an already-running seek target");
    puts("PASS: Actual extracted rotation refresh and seek queue preserve lifecycle state");
    return 0;
}
'''
    program = "\n".join(("#include <stdbool.h>\n#include <stdio.h>\n#include <stdlib.h>",
                         declarations, boundary, *functions, cases))
    with tempfile.TemporaryDirectory(prefix="chengying-rotation-source-") as directory:
        binary = Path(directory) / "RotationSourceTests"
        subprocess.run(
            ["xcrun", "clang", "-x", "c", "-", "-Wall", "-Wextra", "-Werror",
             "-O1", "-g", "-fsanitize=address,undefined", "-o", str(binary)],
            input=program, text=True, check=True, timeout=30,
        )
        result = subprocess.run([str(binary)], capture_output=True, text=True,
                                check=False, timeout=15)
        if args.expect_regression:
            expected = "FAIL: Rotation refresh preserves EOF during teardown"
            if result.returncode != 1 or result.stderr.strip() != expected:
                raise AssertionError(f"Original source did not reproduce the target regression: {result}")
            print("PASS: Original pinned source fails the exact EOF teardown invariant")
        else:
            print(result.stdout, end="")
            if result.returncode:
                raise AssertionError(result.stderr)


if __name__ == "__main__":
    main()
