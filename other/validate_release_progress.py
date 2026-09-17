"""Prevent an older tag or build number from replacing the stable update feed."""

import argparse
import base64
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

from verify_appcast import SPARKLE, require, signed_content, version_tuple


def validate_progress(previous_tag, current_tag, previous_configuration, feed_data):
    for tag in (previous_tag, current_tag):
        require(
            re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag),
            "Stable releases require numeric version tags.",
        )
    require(
        version_tuple(current_tag[1:]) > version_tuple(previous_tag[1:]),
        "Refusing to publish a non-newer stable version.",
    )
    require(
        previous_configuration.get("type") == "file"
        and previous_configuration.get("path") == "Configs/Deployment.xcconfig"
        and previous_configuration.get("encoding") == "base64",
        "Unexpected previous release configuration response.",
    )
    encoded = previous_configuration.get("content", "")
    require(isinstance(encoded, str), "Missing previous release configuration.")
    configuration = base64.b64decode("".join(encoded.split()), validate=True).decode(
        "utf-8"
    )
    builds = re.findall(
        r"(?m)^CURRENT_PROJECT_VERSION\s*=\s*([1-9][0-9]*)\s*$", configuration
    )
    versions = re.findall(
        r"(?m)^MARKETING_VERSION\s*=\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$", configuration
    )
    require(
        len(builds) == 1 and versions == [previous_tag[1:]],
        "Previous release version configuration is ambiguous.",
    )
    # The build job has independently verified this immutable artifact's signature.
    content, _ = signed_content(feed_data)
    root = ET.fromstring(content)
    items = root.findall("channel/item")
    require(len(items) == 1, "Expected one signed release item.")
    item = items[0]
    require(
        item.findtext(SPARKLE + "shortVersionString") == current_tag[1:],
        "Published tag/feed mismatch.",
    )
    current_build = item.findtext(SPARKLE + "version", "")
    require(re.fullmatch(r"[1-9][0-9]*", current_build), "Invalid signed build number.")
    require(
        int(current_build) > int(builds[0]),
        "Refusing to publish a non-newer build number.",
    )
    print("Stable release version and build number both increase.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--previous-tag", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--previous-configuration", type=Path, required=True)
    parser.add_argument("--appcast", type=Path, required=True)
    args = parser.parse_args()
    validate_progress(
        args.previous_tag,
        args.tag,
        json.loads(args.previous_configuration.read_text()),
        args.appcast.read_bytes(),
    )


if __name__ == "__main__":
    main()
