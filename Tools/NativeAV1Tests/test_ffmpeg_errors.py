"""Compile actual locked FFmpeg functions with explicit resource boundaries."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import test_patch_application as patches

ROOT = patches.ROOT


def function(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor]


class FFmpegErrorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        patches.PatchApplicationTests.setUpClass()
        fixture = patches.PatchApplicationTests("test_exact_patch_and_record")
        fixture.setUp()
        cls.fixture = fixture
        result = fixture.apply()
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        cls.source = fixture.source / "ffmpeg-7.1.5"
        cls.evidence = Path(tempfile.mkdtemp(prefix="native-av1-resource-boundary.", dir=ROOT / "build"))
        cls.generated = {}
        decoder = (ROOT / "iina/NativePlayback/CYNMediaDecoder.m").read_text()
        bootstrap = decoder[decoder.index("typedef struct {\n  BOOL active"):decoder.index("} CYNAV1Bootstrap;") + len("} CYNAV1Bootstrap;")]
        callback = function(decoder, "static enum AVPixelFormat CYNVideoFormat(")
        predicate = function(decoder, "- (BOOL)canRetryAV1Initialization:")
        cls.prefix = (ROOT / "Tools/NativeAV1Tests/FFmpegErrorBoundary.h").read_text() + bootstrap + callback
        cls.prefix += "\n@interface RetryBoundary : NSObject { @public CYNInput _input; NSError *_failure; CYNAV1Bootstrap _av1Bootstrap; BOOL _av1ProducedVideo, _av1SoftwareSelected; }\n- (BOOL)canRetryAV1Initialization:(int)result;\n@end\n@implementation RetryBoundary\n" + predicate + "\n@end\n"
        cls.get_format = function((cls.source / "libavcodec/decode.c").read_text(), "int ff_get_format(")
        cls.end_frame = function((cls.source / "libavcodec/videotoolbox_av1.c").read_text(), "static int videotoolbox_av1_end_frame(")
        cls.main = (ROOT / "Tools/NativeAV1Tests/FFmpegErrorMain.m").read_text()
        inputs = [ROOT / "iina/NativePlayback/CYNMediaDecoder.m", Path(__file__), Path(patches.__file__),
                  ROOT / "Tools/NativeAV1Tests/FFmpegErrorBoundary.h", ROOT / "Tools/NativeAV1Tests/FFmpegErrorMain.m",
                  ROOT / "other/playback_ffmpeg_patches.sh"]
        inputs += sorted((ROOT / "other/patches").glob("playback-ffmpeg-*"))
        inputs += sorted((ROOT / "other/patches").glob("ffmpeg-7.1.5-av1-*.patch"))
        for filename in ("decode.c", "videotoolbox_av1.c"):
            path = cls.evidence / filename
            path.write_bytes((cls.source / "libavcodec" / filename).read_bytes())
            inputs.append(path)
        cls.before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
        (cls.evidence / "source.sha256").write_text("".join(value + "  " + name + "\n" for name, value in cls.before.items()))

    @classmethod
    def tearDownClass(cls):
        changed = [name for name, expected in {**cls.before, **cls.generated}.items()
                   if not Path(name).is_file() or hashlib.sha256(Path(name).read_bytes()).hexdigest() != expected]
        (cls.evidence / "hash-validation.json").write_text(json.dumps({"changed": changed}, indent=2) + "\n")
        (cls.evidence / "generated.sha256").write_text("".join(value + "  " + name + "\n" for name, value in cls.generated.items()))
        cls.fixture.doCleanups()
        print(f"FFmpeg resource evidence: {cls.evidence}")
        if changed:
            raise AssertionError("Resource boundary source/generated files changed during testing")

    def compile_run(self, name, get_format, end_frame):
        source = self.evidence / (name + ".m")
        source.write_text(self.prefix + get_format + end_frame + self.main)
        self.generated[str(source)] = hashlib.sha256(source.read_bytes()).hexdigest()
        executable = self.evidence / name
        compiled = subprocess.run(["xcrun", "clang", "-fobjc-arc", "-std=gnu11", "-Wall", "-Wextra",
                                   "-framework", "Foundation", str(source), "-o", str(executable)],
                                  capture_output=True, text=True, timeout=45)
        self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
        (self.evidence / (name + ".log")).write_text(result.stdout + result.stderr)
        return result

    def test_real_resource_paths(self):
        result = self.compile_run("positive", self.get_format, self.end_frame)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_negative_removed_get_format_resource_guard(self):
        guard = """            if (avctx->codec_id == AV_CODEC_ID_AV1 &&
                (err == AVERROR(ENOMEM) || err == AVERROR_EXIT)) {
                ret = AV_PIX_FMT_NONE;
                break;
            }
"""
        self.assertEqual(self.get_format.count(guard), 1)
        result = self.compile_run("negative-format", self.get_format.replace(guard, ""), self.end_frame)
        self.assertEqual(result.returncode, 1)
        self.assertIn("CYN does not retry generalized resource/exit failure", result.stderr)

    def test_negative_ignored_append_error(self):
        guard = "        if (ret < 0)\n            return ret;"
        self.assertEqual(self.end_frame.count(guard), 1)
        result = self.compile_run("negative-append", self.get_format, self.end_frame.replace(guard, "        (void)ret;"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("Truncated AV1 bitstream is never submitted", result.stderr)


if __name__ == "__main__":
    unittest.main()
