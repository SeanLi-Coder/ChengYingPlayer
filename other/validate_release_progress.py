"""Prevent an older tag or build number from replacing the stable update feed."""

import argparse
import base64
import json
import plistlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path

from verify_appcast import (
    BUNDLE_ID,
    FEED_URL,
    SPARKLE,
    decode_public_key,
    require,
    signed_content,
    validate_info,
    validate_update_settings,
    verify_feed_signature,
    version_tuple,
)


def contents_bytes(response, expected_path):
    require(
        isinstance(response, dict)
        and response.get("type") == "file"
        and response.get("path") == expected_path
        and response.get("encoding") == "base64",
        "Unexpected previous release configuration response.",
    )
    encoded = response.get("content", "")
    require(
        isinstance(encoded, str) and len(encoded) <= 2 * 1024 * 1024,
        "Missing or oversized previous release configuration.",
    )
    content = base64.b64decode("".join(encoded.split()), validate=True)
    require(len(content) <= 1024 * 1024, "Previous release configuration is too large.")
    return content


def validate_source_identity(info, configuration):
    require(isinstance(info, dict), "Invalid source application plist.")
    require(isinstance(configuration, str), "Invalid project configuration.")
    identities = re.findall(
        r"(?m)^[ \t]*PRODUCT_BUNDLE_IDENTIFIER[ \t]*=[ \t]*([^\s]+)[ \t]*$",
        configuration,
    )
    require(identities == [BUNDLE_ID], "Application update identity must remain fixed.")
    # Xcode generates CFBundleIdentifier when the source plist omits it.
    if "CFBundleIdentifier" in info:
        require(
            info["CFBundleIdentifier"]
            in (BUNDLE_ID, "$(PRODUCT_BUNDLE_IDENTIFIER)", "${PRODUCT_BUNDLE_IDENTIFIER}"),
            "Source plist overrides the fixed application identity.",
        )


def validate_continuity(
    previous_info, info, previous_project_configuration, project_configuration
):
    old_info = plistlib.loads(contents_bytes(previous_info, "iina/Info.plist"))
    old_configuration = contents_bytes(
        previous_project_configuration, "Configs/iina.xcconfig"
    ).decode("utf-8")
    validate_source_identity(old_info, old_configuration)
    validate_source_identity(info, project_configuration)
    require(old_info.get("SUFeedURL") == FEED_URL, "Previous release used another update feed.")
    old_key = decode_public_key(old_info.get("SUPublicEDKey"))
    current_key = validate_update_settings(info)
    require(
        old_key == current_key,
        "The public update key changed; installed versions cannot trust this release.",
    )
    return old_key


def validate_progress(
    previous_tag,
    current_tag,
    previous_configuration,
    feed_data,
    *,
    previous_info,
    info,
    previous_project_configuration,
    project_configuration,
    built_info=None,
):
    for tag in (previous_tag, current_tag):
        require(
            re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag),
            "Stable releases require numeric version tags.",
        )
    require(
        version_tuple(current_tag[1:]) > version_tuple(previous_tag[1:]),
        "Refusing to publish a non-newer stable version.",
    )
    configuration = contents_bytes(
        previous_configuration, "Configs/Deployment.xcconfig"
    ).decode("utf-8")
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
    old_key = validate_continuity(
        previous_info, info, previous_project_configuration, project_configuration
    )
    if built_info is not None:
        built_key = validate_info(built_info, current_tag)
        require(built_key == old_key, "Built application changed the trusted update key.")
        require(
            built_info["CFBundleVersion"] == current_build,
            "Built application and signed feed build numbers differ.",
        )
        # This macOS-only gate runs before uploading the immutable release artifact.
        verify_feed_signature(feed_data, old_key)
    print("Stable version, build, update identity and signing key continuity verified.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--previous-tag", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--previous-configuration", type=Path, required=True)
    parser.add_argument("--appcast", type=Path, required=True)
    parser.add_argument("--previous-info", type=Path, required=True)
    parser.add_argument("--info-plist", type=Path, required=True)
    parser.add_argument("--previous-project-configuration", type=Path, required=True)
    parser.add_argument("--project-configuration", type=Path, required=True)
    parser.add_argument("--built-info-plist", type=Path)
    args = parser.parse_args()
    validate_progress(
        args.previous_tag,
        args.tag,
        json.loads(args.previous_configuration.read_text()),
        args.appcast.read_bytes(),
        previous_info=json.loads(args.previous_info.read_text()),
        info=plistlib.loads(args.info_plist.read_bytes()),
        previous_project_configuration=json.loads(
            args.previous_project_configuration.read_text()
        ),
        project_configuration=args.project_configuration.read_text(),
        built_info=(
            plistlib.loads(args.built_info_plist.read_bytes())
            if args.built_info_plist is not None
            else None
        ),
    )


if __name__ == "__main__":
    main()
