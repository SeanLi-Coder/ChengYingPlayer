"""Verify the signed Apple Silicon release feed and archive without private keys."""

from __future__ import annotations

import argparse
import base64
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

REPOSITORY = "SeanLi-Coder/ChengYingPlayer"
RELEASES = f"https://github.com/{REPOSITORY}/releases"
FEED_URL = f"{RELEASES}/latest/download/appcast.xml"
BUNDLE_ID = "io.github.SeanLi-Coder.ChengYingPlayer"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
SIGNING_PREFIX = b"<!-- sparkle-signatures:\n"
SIGNING_BLOCK = re.compile(
    rb"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]{86}==)\n"
    rb"length: ([1-9][0-9]*)\n-->\n?\Z"
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def decode_public_key(value):
    require(isinstance(value, str), "Missing public update key.")
    raw = base64.b64decode(value, validate=True)
    require(len(raw) == 32, "Invalid public update key size.")
    require(base64.b64encode(raw).decode() == value, "Noncanonical public update key.")
    return value


def version_tuple(value):
    require(
        isinstance(value, str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value),
        "Invalid numeric version.",
    )
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def validate_update_settings(info):
    require(isinstance(info, dict), "Invalid application update configuration.")
    require(info.get("SUFeedURL") == FEED_URL, "Unexpected update feed URL.")
    public_key = decode_public_key(info.get("SUPublicEDKey"))
    required = {
        "SUEnableAutomaticChecks": True,
        "SUAllowsAutomaticUpdates": True,
        "SUAutomaticallyUpdate": False,
        "SURequireSignedFeed": True,
        "SUVerifyUpdateBeforeExtraction": True,
    }
    for key, expected in required.items():
        require(info.get(key) is expected, f"Unexpected update setting: {key}.")
    expiration = info.get("SUSignedFeedFailureExpirationInterval")
    require(
        type(expiration) is int and expiration == 0,
        "Feed verification must fail closed.",
    )
    return public_key


def validate_info(info, tag):
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag), "Invalid release tag.")
    require(info.get("CFBundleIdentifier") == BUNDLE_ID, "Unexpected app identity.")
    require(info.get("CFBundleShortVersionString") == tag[1:], "Tag/version mismatch.")
    build = info.get("CFBundleVersion")
    require(
        isinstance(build, str) and re.fullmatch(r"[1-9][0-9]*", build),
        "Invalid build number.",
    )
    key = validate_update_settings(info)
    require(
        version_tuple(info.get("LSMinimumSystemVersion")) == (12, 0, 0),
        "Unexpected minimum macOS version.",
    )
    return key


def signed_content(data):
    require(len(data) <= 1024 * 1024, "Feed exceeds the release size limit.")
    require(data.count(SIGNING_PREFIX) == 1, "Expected exactly one feed signature.")
    offset = data.index(SIGNING_PREFIX)
    match = SIGNING_BLOCK.fullmatch(data[offset:])
    require(match is not None, "Malformed or trailing unsigned feed data.")
    content = data[:offset]
    require(int(match[2]) == len(content), "Signed feed length mismatch.")
    require(
        b"<!DOCTYPE" not in content.upper() and b"<!ENTITY" not in content.upper(),
        "External XML declarations are forbidden.",
    )
    return content, match[1].decode()


def validate_feed(content, archive, info, tag):
    root = ET.fromstring(content)
    require(
        root.tag == "rss" and root.attrib == {"version": "2.0"}, "Unexpected RSS root."
    )
    require(
        len(root) == 1 and root[0].tag == "channel", "Expected one release channel."
    )
    channel = root[0]
    items = channel.findall("item")
    require(
        len(items) == 1 and len(root.findall(".//item")) == 1,
        "Expected exactly one release item.",
    )
    item = items[0]
    require(not item.attrib, "Unexpected release item attributes.")
    allowed = {"title", "link", "pubDate", "description", "enclosure"} | {
        SPARKLE + name
        for name in (
            "version",
            "shortVersionString",
            "minimumSystemVersion",
            "hardwareRequirements",
        )
    }
    require(
        all(child.tag in allowed for child in item),
        "Unexpected update policy or external release notes.",
    )
    require(
        len({child.tag for child in item}) == len(item), "Duplicate update metadata."
    )
    for child in item:
        require(len(child) == 0, "Nested update metadata is forbidden.")
        if child.tag != "enclosure":
            require(not child.attrib, "Unexpected update metadata attributes.")
    require(
        item.findtext(SPARKLE + "version") == info["CFBundleVersion"],
        "Feed build mismatch.",
    )
    require(
        item.findtext(SPARKLE + "shortVersionString") == tag[1:],
        "Feed release version mismatch.",
    )
    require(
        version_tuple(item.findtext(SPARKLE + "minimumSystemVersion")) == (12, 0, 0),
        "Feed minimum macOS mismatch.",
    )
    require(
        item.findtext(SPARKLE + "hardwareRequirements") == "arm64",
        "Feed must require Apple Silicon.",
    )
    require(item.findtext("link") == RELEASES, "Unexpected release website.")
    enclosure = item.find("enclosure")
    require(enclosure is not None, "Missing update archive.")
    require(
        set(enclosure.attrib) == {"url", "length", "type", SPARKLE + "edSignature"},
        "Unexpected enclosure attributes.",
    )
    expected_name = f"ChengYingPlayer-{tag}-Apple-Silicon.dmg"
    require(archive.name == expected_name, "Unexpected archive filename.")
    require(
        enclosure.get("url") == f"{RELEASES}/download/{tag}/{expected_name}",
        "Update URL is not this repository's exact tagged asset.",
    )
    require(
        enclosure.get("type") == "application/octet-stream",
        "Unexpected update archive type.",
    )
    require(
        enclosure.get("length") == str(archive.stat().st_size),
        "Update archive size mismatch.",
    )
    signature = enclosure.get(SPARKLE + "edSignature", "")
    require(
        re.fullmatch(r"[A-Za-z0-9+/]{86}==", signature),
        "Invalid update archive signature.",
    )
    return signature


def compile_verifier(destination):
    source = Path(__file__).with_name("verify_ed25519.swift")
    subprocess.run(["xcrun", "swiftc", str(source), "-o", str(destination)], check=True)


def verify_feed_signature(data, public_key, verifier=None):
    """Verify feed bytes against an already trusted public key on macOS."""
    decode_public_key(public_key)
    content, signature = signed_content(data)
    with tempfile.TemporaryDirectory(prefix="chengying-feed-signature-") as directory:
        temporary = Path(directory)
        if verifier is None:
            verifier = temporary / "verify-ed25519"
            compile_verifier(verifier)
        body = temporary / "signed-feed.xml"
        body.write_bytes(content)
        subprocess.run([str(verifier), public_key, signature, str(body)], check=True)
    return content


def verify(appcast, archive, info, tag, verifier=None):
    for path in (appcast, archive):
        require(
            path.is_file() and not path.is_symlink(),
            "Release input must be a regular file.",
        )
    public_key = validate_info(info, tag)
    with tempfile.TemporaryDirectory(prefix="chengying-feed-verify-") as directory:
        temporary = Path(directory)
        if verifier is None:
            verifier = temporary / "verify-ed25519"
            compile_verifier(verifier)
        content = verify_feed_signature(appcast.read_bytes(), public_key, verifier)
        archive_signature = validate_feed(content, archive, info, tag)
        subprocess.run(
            [str(verifier), public_key, archive_signature, str(archive)], check=True
        )
    print("Signed feed, archive, version, repository, macOS and ARM64 policy verified.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", required=True, type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--info-plist", required=True, type=Path)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    with args.info_plist.open("rb") as stream:
        info = plistlib.load(stream)
    verify(args.appcast, args.archive, info, args.tag)


if __name__ == "__main__":
    main()
