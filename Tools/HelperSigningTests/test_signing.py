"""Exercise real onefile helpers after Xcode-style signing without changing inputs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
REQUIRED_ENTITLEMENT = "com.apple.security.cs.disable-library-validation"
HELPER_KINDS = ("video", "subtitle")


class SigningError(RuntimeError):
    """A signature or its runtime behavior violates the helper release policy."""


def command(arguments: list[str], *, input_text: str | None = None, check: bool = True):
    result = subprocess.run(
        arguments,
        input=input_text,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if check and result.returncode != 0:
        raise SigningError(
            f"Command failed ({result.returncode}): {arguments!r}\n"
            f"{result.stdout}\n{result.stderr}"
        )
    return result


def signature_entitlements(path: Path) -> dict:
    result = command(
        [
            "codesign",
            "--display",
            "--entitlements",
            "-",
            "--xml",
            str(path),
        ]
    )
    if not result.stdout.strip():
        return {}
    try:
        payload = plistlib.loads(result.stdout.encode("utf-8"))
    except (ValueError, plistlib.InvalidFileException) as exc:
        raise SigningError(f"Invalid signature entitlements: {path}") from exc
    if not isinstance(payload, dict):
        raise SigningError(f"Signature entitlements are not a dictionary: {path}")
    return payload


def require_helper_signature(path: Path, *, runtime: bool = False) -> None:
    command(["codesign", "--verify", "--strict", str(path)])
    entitlements = signature_entitlements(path)
    if entitlements.get(REQUIRED_ENTITLEMENT) is not True:
        raise SigningError(f"Missing required library-validation entitlement: {path}")
    if set(entitlements) != {REQUIRED_ENTITLEMENT}:
        raise SigningError(f"Unexpected additional helper entitlements: {path}")
    if runtime:
        details = command(["codesign", "-dvv", str(path)])
        match = re.search(r"\bflags=0x([0-9a-fA-F]+)", details.stderr)
        if match is None or not int(match.group(1), 16) & 0x10000:
            raise SigningError(f"The copied helper lost Hardened Runtime: {path}")


def snapshot(path: Path) -> tuple[str, int, int]:
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    stat = path.stat()
    return digest, stat.st_mode, stat.st_mtime_ns


def smoke_helper(kind: str, path: Path, binaries: Path, root: Path) -> None:
    result = command([str(path), "--help"])
    if "--ffmpeg" not in result.stdout or "--stdio" not in result.stdout:
        raise SigningError(f"The frozen helper did not start: {path}")
    args = [
        str(path),
        "--ffmpeg",
        str(binaries / "ffmpeg"),
        "--ffprobe",
        str(binaries / "ffprobe"),
        "--stdio",
    ]
    request = "ping"
    response = "pong"
    if kind == "subtitle":
        args.extend(["--data-dir", str(root / "subtitle-offline-data")])
        request, response = "status", "status"
    requests = [
        {"id": "signing-smoke", "command": request},
        {"id": "signing-shutdown", "command": "shutdown"},
    ]
    result = command(
        args, input_text="".join(json.dumps(item) + "\n" for item in requests)
    )
    try:
        events = [
            json.loads(line) for line in result.stdout.splitlines() if line.strip()
        ]
    except json.JSONDecodeError as exc:
        raise SigningError(f"The frozen helper emitted invalid JSON: {path}") from exc
    if not any(event.get("type") == "ready" for event in events):
        raise SigningError(f"The frozen helper emitted no ready event: {path}")
    replies = [event for event in events if event.get("type") == response]
    if not replies:
        raise SigningError(f"The frozen helper emitted no {response} event: {path}")
    if kind == "subtitle" and replies[0].get("runtime_ready") is not False:
        raise SigningError(
            "The subtitle signing test must use an empty offline runtime"
        )
    shutdown_events = [
        event for event in events if event.get("id") == "signing-shutdown"
    ]
    acknowledged_shutdown = (
        any(event.get("type") == "completed" for event in shutdown_events)
        if kind == "subtitle"
        else any(event.get("action") == "shutdown" for event in shutdown_events)
    )
    if not acknowledged_shutdown:
        raise SigningError(f"The frozen helper did not acknowledge shutdown: {path}")


def local_library_validation_expected() -> bool:
    if os.environ.get("GITHUB_ACTIONS", "").lower() == "true":
        return False
    result = command(["/usr/bin/csrutil", "status"], check=False)
    return result.returncode == 0 and result.stdout.strip() == (
        "System Integrity Protection status: enabled."
    )


def run(binaries: Path) -> None:
    if sys.platform != "darwin":
        raise SigningError("Helper signing regression tests require macOS")
    binaries = binaries.expanduser().resolve(strict=True)
    originals = {
        kind: binaries / f"chengying-{kind}-tools-helper" for kind in HELPER_KINDS
    }
    for path in [*originals.values(), binaries / "ffmpeg", binaries / "ffprobe"]:
        if not path.is_file() or not os.access(path, os.X_OK):
            raise SigningError(f"Required bundled executable is missing: {path}")
    original_snapshots = {kind: snapshot(path) for kind, path in originals.items()}
    enforce_negative_launch = local_library_validation_expected()
    try:
        with tempfile.TemporaryDirectory(
            prefix="chengying helper signing "
        ) as temporary:
            root = Path(temporary).resolve()
            application = root / "Signing Fixture.app"
            contents = application / "Contents"
            embedded = contents / "MacOS"
            embedded.mkdir(parents=True)
            copy_stage = root / "Copy Stage"
            copy_stage.mkdir()
            shutil.copyfile("/usr/bin/true", embedded / "host")
            (embedded / "host").chmod(0o755)
            (contents / "Info.plist").write_bytes(
                plistlib.dumps(
                    {
                        "CFBundleIdentifier": "io.github.SeanLi-Coder.ChengYingPlayer.HelperSigningTest",
                        "CFBundleExecutable": "host",
                        "CFBundlePackageType": "APPL",
                    }
                )
            )
            for kind, original in originals.items():
                require_helper_signature(original)
                smoke_helper(kind, original, binaries, root / f"original-{kind}")
                copied = copy_stage / original.name
                shutil.copy2(original, copied)
                # Match the real Xcode CodeSignOnCopy invocation, including its metadata policy.
                command(
                    [
                        "codesign",
                        "--force",
                        "--sign",
                        "-",
                        "-o",
                        "runtime",
                        "--timestamp=none",
                        "--preserve-metadata=identifier,entitlements,flags",
                        "--generate-entitlement-der",
                        str(copied),
                    ]
                )
                require_helper_signature(copied, runtime=True)
                smoke_helper(kind, copied, binaries, root / f"copied-{kind}")

                negative = root / f"stripped-{kind}"
                shutil.copy2(copied, negative)
                command(["codesign", "--remove-signature", str(negative)])
                command(
                    [
                        "codesign",
                        "--force",
                        "--sign",
                        "-",
                        "-o",
                        "runtime",
                        "--timestamp=none",
                        "--generate-entitlement-der",
                        str(negative),
                    ]
                )
                command(["codesign", "--verify", "--strict", str(negative)])
                if signature_entitlements(negative):
                    raise SigningError(
                        "The negative fixture did not remove its entitlements"
                    )
                try:
                    require_helper_signature(negative, runtime=True)
                except SigningError as exc:
                    if "Missing required library-validation entitlement" not in str(
                        exc
                    ):
                        raise
                else:
                    raise SigningError(
                        "The static policy accepted a stripped helper signature"
                    )
                if enforce_negative_launch:
                    failure = command([str(negative), "--help"], check=False)
                    if failure.returncode == 0 or not any(
                        marker in failure.stderr
                        for marker in (
                            "Team ID",
                            "Library Validation",
                            "library validation",
                        )
                    ):
                        raise SigningError(
                            "Local library validation did not reject the negative fixture"
                        )
                print(
                    f"PASS: {kind} original, Xcode-style signature, stdio, and negative entitlement gate",
                    flush=True,
                )
                shutil.copy2(copied, embedded / original.name)

            # The containing application must seal signed helpers without changing their signatures.
            copied_snapshots = {
                kind: snapshot(embedded / path.name) for kind, path in originals.items()
            }
            command(
                [
                    "codesign",
                    "--force",
                    "--sign",
                    "-",
                    "-o",
                    "runtime",
                    str(application),
                ]
            )
            command(["codesign", "--verify", "--deep", "--strict", str(application)])
            for kind, original in originals.items():
                copied = embedded / original.name
                if snapshot(copied) != copied_snapshots[kind]:
                    raise SigningError(
                        "Signing the containing application changed a helper"
                    )
                require_helper_signature(copied, runtime=True)
                smoke_helper(kind, copied, binaries, root / f"sealed-{kind}")
            command(["codesign", "--verify", "--deep", "--strict", str(application)])
            print(
                "PASS: containing app signing, deep verification, and both sealed helper protocols"
            )
            if not enforce_negative_launch:
                print(
                    "INFO: negative execution is policy-dependent; the static negative gate passed"
                )
    finally:
        for kind, original in originals.items():
            if snapshot(original) != original_snapshots[kind]:
                raise SigningError(
                    f"A signing test modified an original helper: {original}"
                )
    print("PASS: original helper bytes, mode, and modification times were preserved")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--helpers-directory", type=Path, default=PROJECT_ROOT / "deps/executable"
    )
    args = parser.parse_args()
    run(args.helpers_directory)


if __name__ == "__main__":
    main()
