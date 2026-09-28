"""Print deterministic synthetic RPU fixture data; requires dovi_tool 2.3.4.

Usage: python generate.py /absolute/path/dovi_tool
No downloaded footage, personal media, or runtime dependency is involved.
"""

import base64
import gzip
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def configuration(profile: str) -> dict:
    edits = []
    for index in range(90):
        edits.append(
            {
                "edit_offset": index,
                "metadata_blocks": [
                    {
                        "Level1": {
                            "min_pq": 2,
                            "max_pq": 2800 + index,
                            "avg_pq": 1200 + index,
                        }
                    },
                    {
                        "Level2": {
                            "target_max_pq": 3079,
                            "trim_slope": 2000 + index,
                            "trim_offset": 2048,
                            "trim_power": 1800,
                            "trim_chroma_weight": 2048,
                            "trim_saturation_gain": 2048,
                            "ms_weight": 2048,
                        }
                    },
                    {
                        "Level5": {
                            "active_area_left_offset": index % 3,
                            "active_area_right_offset": index % 3,
                            "active_area_top_offset": 4 + index % 4,
                            "active_area_bottom_offset": 4 + index % 4,
                        }
                    },
                    {
                        "Level8": {
                            "length": 25,
                            "target_display_index": 1,
                            "trim_slope": 1900 + index,
                            "trim_offset": 2048,
                            "trim_power": 1800,
                            "trim_chroma_weight": 2048,
                            "trim_saturation_gain": 2048,
                            "ms_weight": 2048,
                            "target_mid_contrast": 2048,
                            "clip_trim": 2000,
                            "saturation_vector_field0": 128,
                            "hue_vector_field0": 128,
                        }
                    },
                ],
            }
        )
    return {
        "cm_version": "V40",
        "profile": profile,
        "length": 90,
        "level6": {
            "max_display_mastering_luminance": 1000,
            "min_display_mastering_luminance": 1,
            "max_content_light_level": 1000,
            "max_frame_average_light_level": 400,
        },
        "shots": [
            {"start": 0, "duration": 90, "metadata_blocks": [], "frame_edits": edits}
        ],
    }


if __name__ == "__main__":
    result = {}
    with tempfile.TemporaryDirectory(prefix="synthetic-dovi-") as directory:
        root = Path(directory)
        for compatibility, profile in ((1, "8.1"), (4, "8.4")):
            source = root / "config.json"
            source.write_text(json.dumps(configuration(profile)))
            output = root / "RPU.bin"
            subprocess.run(
                [sys.argv[1], "generate", "-j", str(source), "-o", str(output)],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            raw = output.read_bytes()
            result[str(compatibility)] = {
                "frames": 90,
                "sha256": hashlib.sha256(raw).hexdigest(),
                "gzip_base64": base64.b64encode(gzip.compress(raw, mtime=0)).decode(
                    "ascii"
                ),
            }
    print(json.dumps(result, indent=2))
