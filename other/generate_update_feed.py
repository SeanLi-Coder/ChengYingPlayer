"""Sign a verified release using pinned Sparkle tools and verify with its public key."""

from __future__ import annotations

import argparse
import hashlib
import os
import plistlib
import shutil
import signal
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

from build_delta_update import build_delta, tree_manifest, verify_archive_application
from test_app_workspace import TestAppWorkspace
from verify_appcast import (
    RELEASES,
    SPARKLE,
    require,
    signed_content,
    validate_info,
    verify,
)

SPARKLE_VERSION = "2.10.0"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def validate_sparkle(root):
    framework = root / "Sparkle.framework"
    if not framework.exists():
        framework = root / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    plist = framework / "Versions/B/Resources/Info.plist"
    with plist.open("rb") as stream:
        info = plistlib.load(stream)
    require(
        info.get("CFBundleShortVersionString") == SPARKLE_VERSION,
        "Signing requires the pinned Sparkle version.",
    )
    tool = root / "bin/generate_appcast"
    require(
        tool.is_file() and os.access(tool, os.X_OK),
        "Missing pinned Sparkle signing tool.",
    )
    return tool


def sign_file(tool, path, secret, *, print_signature=False):
    command = [str(tool), "--ed-key-file", "-"]
    if print_signature:
        command.append("-p")
    result = subprocess.run(
        command + [str(path)],
        input=secret.encode(),
        capture_output=True,
        check=False,
        timeout=600,
    )
    # Never print raw signing diagnostics or include credentials in exceptions.
    require(result.returncode == 0, "Sparkle could not sign the verified delta update.")
    return result.stdout.decode("ascii").strip() if print_signature else None


def prepare_signing_cache(tool, app, archive_digest, staging):
    """Keep Sparkle 2.10's extracted archive cache inside this owned workspace."""
    require(
        len(archive_digest) == 64
        and all(character in "0123456789abcdef" for character in archive_digest),
        "The appcast cache requires a canonical archive SHA-256 digest.",
    )
    signing_home = staging / "sparkle-home"
    signing_home.mkdir()
    environment = dict(os.environ, CFFIXED_USER_HOME=str(signing_home))
    environment.pop("SPARKLE_ED25519_PRIVATE_KEY", None)
    help_result = subprocess.run(
        [str(tool), "--help"], env=environment, capture_output=True, timeout=30
    )
    help_text = " ".join(help_result.stdout.decode("utf-8", errors="replace").split())
    require(
        help_result.returncode == 0
        and "Extracted archives that are needed are cached in "
        "~/Library/Caches/Sparkle_generate_appcast " in help_text,
        "The pinned appcast generator's cache layout could not be verified.",
    )
    # Help abbreviates the path with '~'. Check Foundation's actual cache path
    # in a separate child with the same environment before passing any key.
    probe = subprocess.run(
        [
            "/usr/bin/osascript", "-l", "JavaScript", "-e",
            'ObjC.import("Foundation"); '
            '$.NSFileManager.defaultManager.URLsForDirectoryInDomains(13, 1).firstObject.path.js',
        ],
        env=environment, capture_output=True, timeout=30,
    )
    caches = signing_home / "Library/Caches"
    require(
        probe.returncode == 0
        and probe.stdout.decode("utf-8", errors="replace").strip() == str(caches),
        "The appcast generator's cache could not be isolated to its workspace.",
    )
    cache = caches / "Sparkle_generate_appcast"
    destination = cache / archive_digest
    destination.mkdir(parents=True)
    require(
        destination.resolve(strict=True) == destination
        and staging in destination.parents,
        "The appcast cache escaped its owned workspace.",
    )
    original = tree_manifest(app)
    cached_app = destination / app.name
    shutil.copytree(app, cached_app, symlinks=True)
    require(
        tree_manifest(cached_app) == original == tree_manifest(app),
        "The verified application changed while preparing the appcast cache.",
    )
    return environment, cache, cached_app, original


def generate(
    app, archive, destination, tag, sparkle_root, *, previous_release_directory=None
):
    # Remove the secret from child environments. Only the signing tool gets stdin.
    secret = os.environ.pop("SPARKLE_ED25519_PRIVATE_KEY", "")
    require(bool(secret.strip()), "The release signing secret is not configured.")
    require(
        destination.name == "appcast.xml" and not destination.exists(),
        "Feed output must be a new appcast.xml.",
    )
    require(
        archive.is_file() and not archive.is_symlink(),
        "Archive must be a regular file.",
    )
    info_path = app / "Contents/Info.plist"
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    validate_info(info, tag)
    require(
        archive.name == f"ChengYingPlayer-{tag}-Apple-Silicon.dmg",
        "Unexpected release archive.",
    )
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    architectures = subprocess.check_output(
        ["lipo", "-archs", str(executable)], text=True
    ).split()
    require(architectures == ["arm64"], "Release application must be ARM64-only.")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    tool = validate_sparkle(sparkle_root)
    before = digest(archive)
    with TestAppWorkspace(prefix="chengying-feed-sign-") as directory:
        staging = Path(directory)
        verify_archive_application(archive, app, info, staging)
        delta = None
        if previous_release_directory is not None:
            delta = build_delta(
                app,
                archive,
                tag,
                info,
                previous_release_directory,
                sparkle_root,
                staging,
            )
        # Keep the official full-feed generator isolated from old archives and
        # prebuilt deltas; our delta was already round-tripped before signing.
        signing = staging / "signing"
        signing.mkdir()
        staged_archive = signing / archive.name
        shutil.copyfile(archive, staged_archive)
        environment, cache, cached_app, cached_tree = prepare_signing_cache(
            tool, app, before, staging
        )
        result = subprocess.run(
            [
                str(tool),
                "--ed-key-file",
                "-",
                "--maximum-deltas",
                "0",
                "--verbose",
                "--download-url-prefix",
                f"{RELEASES}/download/{tag}/",
                "--link",
                RELEASES,
                str(signing),
            ],
            input=secret.encode(),
            env=environment,
            capture_output=True,
            check=False,
            timeout=600,
        )
        # Never echo signing-tool diagnostics: malformed credential input must stay private.
        require(
            result.returncode == 0,
            "Sparkle could not sign the release; check the signing configuration.",
        )
        require(
            f"Unarchiving to temp directory {cache}".encode() in result.stdout
            and tree_manifest(cached_app) == cached_tree
            and not os.path.lexists(cache / f"{before}.tmp"),
            "The appcast generator did not preserve its verified local cache.",
        )
        require(
            digest(staged_archive) == before and digest(archive) == before,
            "Archive changed during signing.",
        )
        generated = signing / "appcast.xml"
        extra_assets = []
        if delta is not None:
            delta_file, delta_attributes = delta
            signing_tool = sparkle_root / "bin/sign_update"
            require(
                signing_tool.is_file() and os.access(signing_tool, os.X_OK),
                "Missing pinned Sparkle delta signing tool.",
            )
            before_delta = digest(delta_file)
            delta_signature = sign_file(
                signing_tool, delta_file, secret, print_signature=True
            )
            content, _ = signed_content(generated.read_bytes())
            ET.register_namespace("sparkle", SPARKLE[1:-1])
            tree = ET.fromstring(content)
            item = tree.find("channel/item")
            require(item is not None, "Missing generated release item.")
            deltas = ET.SubElement(item, SPARKLE + "deltas")
            ET.SubElement(
                deltas,
                "enclosure",
                {
                    "url": f"{RELEASES}/download/{tag}/{delta_file.name}",
                    "length": str(delta_file.stat().st_size),
                    "type": "application/octet-stream",
                    SPARKLE + "edSignature": delta_signature,
                    **delta_attributes,
                },
            )
            generated.write_bytes(
                ET.tostring(tree, encoding="utf-8", xml_declaration=True)
            )
            sign_file(signing_tool, generated, secret)
            require(digest(delta_file) == before_delta, "Delta changed during signing.")
            checksum = delta_file.with_suffix(".delta.sha256")
            checksum.write_text(
                f"{before_delta}  {delta_file.name}\n", encoding="ascii"
            )
            extra_assets = [delta_file, checksum]
        secret = ""
        verify(generated, archive, info, tag, delta_directory=staging)
        destination.parent.mkdir(parents=True, exist_ok=True)
        require(
            all(
                not (destination.parent / asset.name).exists() for asset in extra_assets
            ),
            "Refusing to overwrite existing delta release assets.",
        )
        for asset in extra_assets:
            with (
                asset.open("rb") as source,
                (destination.parent / asset.name).open("xb") as output,
            ):
                shutil.copyfileobj(source, output)
        with destination.open("xb") as output:
            output.write(generated.read_bytes())
    print(
        "Signed appcast created and independently verified without exposing credentials."
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--sparkle-root", required=True, type=Path)
    parser.add_argument("--previous-release-directory", type=Path)
    args = parser.parse_args()
    generate(
        args.app,
        args.archive,
        args.output,
        args.tag,
        args.sparkle_root,
        previous_release_directory=args.previous_release_directory,
    )


if __name__ == "__main__":
    def interrupted(_number, _frame):
        raise KeyboardInterrupt

    for termination_signal in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(termination_signal, interrupted)
    main()
