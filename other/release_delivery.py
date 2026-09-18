"""Upload complete draft assets and verify the public automatic-update route."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

from verify_appcast import FEED_URL, RELEASES, REPOSITORY, SPARKLE, require, signed_content


def asset_names(tag):
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag), "Invalid stable release tag.")
    prefix = f"ChengYingPlayer-{tag}"
    return (
        prefix + "-Apple-Silicon.dmg",
        prefix + "-Apple-Silicon.dmg.sha256",
        prefix + "-Release-Source.tar.gz",
        prefix + "-Release-Source.tar.gz.sha256",
        prefix + "-Third-Party-Source-Manifest.txt",
        "appcast.xml",
    )


def gh(*arguments):
    result = subprocess.run(
        ["gh", *arguments, "--repo", REPOSITORY],
        capture_output=True, text=True, check=True, timeout=240,
    )
    return result.stdout


def draft_assets(tag, expected_names, run):
    release = json.loads(run("release", "view", tag, "--json", "tagName,isDraft,isPrerelease,assets"))
    require(
        release.get("tagName") == tag and release.get("isDraft") is True
        and release.get("isPrerelease") is False,
        "Uploads require the exact stable draft release.",
    )
    assets = release.get("assets")
    require(isinstance(assets, list) and all(isinstance(item, dict) for item in assets), "Invalid draft assets.")
    names = [item.get("name") for item in assets]
    require(len(names) == len(set(names)) and all(name in expected_names for name in names),
            "Refusing to modify a draft with unexpected or duplicate assets.")
    return {item["name"]: item for item in assets}


def upload_assets(tag, directory, run=gh, wait=time.sleep):
    expected = asset_names(tag)
    manifest = {}
    for name in expected:
        local = directory / name
        require(local.is_file() and not local.is_symlink() and local.stat().st_size > 0,
                "Every release asset must be a nonempty regular file.")
        with local.open("rb") as stream:
            digest = "sha256:" + hashlib.file_digest(stream, "sha256").hexdigest()
        manifest[name] = (local.stat().st_size, digest)

    def matches(asset, name):
        return asset is not None and asset.get("state") == "uploaded" and (
            asset.get("size"), asset.get("digest")) == manifest[name]

    for name in expected:
        for attempt in range(1, 4):
            # Re-read before every mutation, including retries after ambiguous failures.
            remote = draft_assets(tag, expected, run).get(name)
            if matches(remote, name):
                print(f"Verified release asset already uploaded: {name}")
                break
            require(remote is None, f"Existing release asset conflicts with verified local bytes: {name}")
            print(f"Uploading release asset: {name} (attempt {attempt}/3)")
            try:
                # Never delete an existing asset, even if another actor publishes now.
                run("release", "upload", tag, str(directory / name))
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                # A server can accept bytes before the connection fails. Check first.
                pass
            remote = draft_assets(tag, expected, run).get(name)
            if matches(remote, name):
                break
            require(attempt < 3, f"Release asset did not pass upload verification: {name}")
            wait(5 * attempt)
    final = draft_assets(tag, expected, run)
    require(set(final) == set(expected) and all(matches(final[name], name) for name in expected),
            "Draft asset set changed during upload verification.")
    print("All six stable draft assets are uploaded and match their local SHA-256 digests.")


def safe_url(url):
    parsed = urllib.parse.urlsplit(url)
    return (parsed.scheme == "https" and parsed.username is None and parsed.password is None
            and parsed.port in (None, 443) and not parsed.fragment
            and (parsed.hostname in {"github.com", "api.github.com"}
                 or (parsed.hostname or "").endswith(".githubusercontent.com")))


class ReleaseRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        require(safe_url(new_url), "Unexpected public release redirect.")
        redirected = super().redirect_request(request, response, code, message, headers, new_url)
        if redirected is not None and request.get_method() == "HEAD":
            redirected.method = "HEAD"
        return redirected


def public_request(url, method="GET"):
    require(safe_url(url), "Unexpected public release URL.")
    # No GH_TOKEN, Authorization header or authenticated gh download is used here.
    request = urllib.request.Request(url, method=method, headers={
        "User-Agent": "ChengYing-Update-Delivery-Check",
        "Accept": "application/json" if url.startswith("https://api.github.com/") else "*/*",
        "Cache-Control": "no-cache",
    })
    opener = urllib.request.build_opener(ReleaseRedirects())
    with opener.open(request, timeout=20) as response:
        require(response.status == 200, "Public release endpoint is not ready.")
        body = b"" if method == "HEAD" else response.read(1024 * 1024 + 1)
        require(len(body) <= 1024 * 1024, "Public release response is too large.")
        return body, dict(response.headers.items())


def verify_download(url, expected_size, expected_digest, opener=None, clock=time.monotonic):
    require(safe_url(url), "Unexpected public archive URL.")
    opener = opener or urllib.request.build_opener(ReleaseRedirects())
    request = urllib.request.Request(url, headers={
        "User-Agent": "ChengYing-Update-Delivery-Check", "Cache-Control": "no-cache",
    })
    started = clock()
    digest = hashlib.sha256()
    received = 0
    with opener.open(request, timeout=20) as response:
        require(response.status == 200, "Public DMG download failed.")
        while True:
            require(clock() - started < 300, "Public DMG download exceeded its time limit.")
            chunk = response.read1(min(1024 * 1024, expected_size - received + 1))
            require(clock() - started < 300, "Public DMG download exceeded its time limit.")
            if not chunk:
                break
            received += len(chunk)
            require(received <= expected_size, "Public DMG download exceeds the verified size.")
            digest.update(chunk)
    require(received == expected_size and digest.hexdigest() == expected_digest,
            "Public DMG download bytes differ from the verified build artifact.")


def verify_public(tag, feed_data, local_archive, request=public_request, download=verify_download):
    names = asset_names(tag)
    require(local_archive.name == names[0] and local_archive.is_file() and not local_archive.is_symlink(),
            "Expected the exact locally verified DMG.")
    with local_archive.open("rb") as stream:
        archive_digest = hashlib.file_digest(stream, "sha256").hexdigest()
    content, _ = signed_content(feed_data)
    root = ET.fromstring(content)
    items = root.findall("channel/item")
    require(len(items) == 1, "Expected one verified update item.")
    item = items[0]
    require(item.findtext(SPARKLE + "shortVersionString") == tag[1:], "Update feed tag mismatch.")
    archive = item.find("enclosure")
    require(archive is not None, "Missing update archive.")
    archive_url = f"{RELEASES}/download/{tag}/{names[0]}"
    require(archive.get("url") == archive_url, "Unexpected version-pinned update URL.")
    size = archive.get("length", "")
    require(re.fullmatch(r"[1-9][0-9]*", size), "Invalid update archive size.")
    require(local_archive.stat().st_size == int(size), "Local DMG size differs from the signed feed.")
    release_data, _ = request(f"https://api.github.com/repos/{REPOSITORY}/releases/latest")
    release = json.loads(release_data)
    require(release.get("tag_name") == tag and release.get("draft") is False
            and release.get("prerelease") is False, "The new stable version is not the public latest release.")
    assets = release.get("assets", [])
    require(isinstance(assets, list) and all(isinstance(asset, dict) for asset in assets)
            and len(assets) == len(names) and {asset.get("name") for asset in assets} == set(names),
            "Public release is missing its exact required asset set.")
    require(all(asset.get("state") == "uploaded" for asset in assets), "A public release asset is incomplete.")
    by_name = {asset["name"]: asset for asset in assets}
    require(by_name[names[0]].get("size") == int(size), "Public DMG size differs from the signed feed.")
    require(by_name[names[0]].get("digest") == "sha256:" + archive_digest,
            "Public DMG asset digest differs from the verified build artifact.")
    require(by_name["appcast.xml"].get("digest") == "sha256:" + hashlib.sha256(feed_data).hexdigest(),
            "Public feed asset digest differs from the verified build artifact.")
    public_feed, _ = request(FEED_URL)
    require(public_feed == feed_data, "The exact installed-app feed URL returned stale or changed bytes.")
    download(archive_url, int(size), archive_digest)
    print("The public latest release, installed-app feed URL and anonymously downloaded DMG match the verified build.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    upload = commands.add_parser("upload")
    upload.add_argument("--tag", required=True)
    upload.add_argument("--directory", type=Path, required=True)
    public = commands.add_parser("verify-public")
    public.add_argument("--tag", required=True)
    public.add_argument("--appcast", type=Path, required=True)
    public.add_argument("--archive", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "upload":
        upload_assets(args.tag, args.directory)
    else:
        feed = args.appcast.read_bytes()
        for attempt in range(1, 7):
            try:
                verify_public(args.tag, feed, args.archive)
                return
            except (OSError, ValueError) as error:
                if attempt == 6:
                    raise SystemExit("Public automatic-update delivery failed verification; the release is not fully verified.") from error
                print(f"Waiting for public automatic-update delivery (attempt {attempt}/6).")
                time.sleep(5 * attempt)


if __name__ == "__main__":
    main()
