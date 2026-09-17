"""Check that every native media-info label is shipped in all supported locales."""

import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sources = list((ROOT / "iina/MediaInfo").glob("*.swift")) + [
    ROOT / "iina/MenuController.swift",
    ROOT / "iina/ImageViewer/ImageViewerWindowController.swift",
    ROOT / "iina/VideoTools/VideoToolsViewController.swift",
]
required = set()
for source in sources:
    required.update(re.findall(r'mediaInfoText\("([^"\\]+)",', source.read_text()))

image = (ROOT / "iina/MediaInfo/ImageMediaInfoReader.swift").read_text()
required.update("image." + key for key in re.findall(r'row\("([a-z_]+)"', image))
required.update(
    "image." + key
    for key in re.findall(r'\("([a-z_]+)", "[^"]+", (?:tiff|exif)\[', image)
)
required.update(f"image.orientation_{orientation}" for orientation in range(1, 9))
video = (ROOT / "iina/MediaInfo/VideoMediaInfoReader.swift").read_text()
required.update(re.findall(r'row\("[^"]+", "(video\.[^"]+)"', video))

tables = {}
for language in ("en", "zh-Hans", "zh-Hant"):
    path = ROOT / "iina" / f"{language}.lproj/MediaInfo.strings"
    tables[language] = json.loads(
        subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)])
    )
    assert required <= tables[language].keys(), (
        language, sorted(required - tables[language].keys())
    )
    assert tables[language].keys() == tables["en"].keys(), language
    for key, value in tables[language].items():
        assert isinstance(value, str) and value.strip(), (language, key)
        assert re.findall(r"%@", value) == re.findall(r"%@", tables["en"][key]), (
            language, key
        )
print(f"PASS: {len(required)} media information keys in three matching locale tables")
