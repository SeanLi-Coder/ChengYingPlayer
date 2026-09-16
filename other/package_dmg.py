"""Package an already signed, self-contained Apple Silicon application without modifying it."""

from __future__ import annotations

import hashlib
import mmap
import os
import plistlib
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

BUNDLE_ID = "io.github.SeanLi-Coder.ChengYingPlayer"
ARM64 = 0x0100000C
MACHO_MAGICS = {
    b"\xcf\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xce",
}
FAT_MAGICS = {
    b"\xca\xfe\xba\xbe": (">", False),
    b"\xbe\xba\xfe\xca": ("<", False),
    b"\xca\xfe\xba\xbf": (">", True),
    b"\xbf\xba\xfe\xca": ("<", True),
}
DEPENDENCY_COMMANDS = {0xC, 0x80000018, 0x8000001F, 0x80000023}
REQUIRED_EXECUTABLES = (
    "Contents/MacOS/ChengYing",
    "Contents/MacOS/ffmpeg",
    "Contents/MacOS/ffprobe",
    "Contents/MacOS/chengying-video-tools-helper",
    "Contents/MacOS/chengying-subtitle-tools-helper",
    "Contents/MacOS/chengying-image-codec",
    "Contents/MacOS/chengying-cli",
    "Contents/Helpers/DownloadCenter.app/Contents/MacOS/chengying-download-center-helper",
    "Contents/Helpers/DownloadCenter.app/Contents/Frameworks/playwright/driver/node",
)
REQUIRED_NOTICES = (
    "ChengYingPlayer-GPLv3.txt",
    "ChengYingPlayer-NOTICE.md",
    "THIRD_PARTY_NOTICES.md",
    "SOURCE_MANIFEST.txt",
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(arguments, *, capture=False):
    return subprocess.run(
        arguments, check=True, stdout=subprocess.PIPE if capture else None
    ).stdout


def inside(path, root):
    return path == root or root in path.parents


def macho_commands(path):
    """Read the ARM64 slice's load commands without loading large helpers into RAM."""
    with path.open("rb") as stream:
        magic = stream.read(4)
        if magic not in MACHO_MAGICS and magic not in FAT_MAGICS:
            return None
        with mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
            offset = 0
            limit = len(data)
            if magic in FAT_MAGICS:
                endian, wide = FAT_MAGICS[magic]
                count = struct.unpack_from(endian + "I", data, 4)[0]
                require(0 < count <= 64, f"Invalid universal Mach-O header: {path}")
                offset = None
                for index in range(count):
                    entry = 8 + index * (32 if wide else 20)
                    cpu = struct.unpack_from(endian + "I", data, entry)[0]
                    start, size = struct.unpack_from(
                        endian + ("QQ" if wide else "II"), data, entry + 8
                    )
                    require(start + size <= len(data), f"Invalid Mach-O slice: {path}")
                    if cpu == ARM64:
                        offset, limit = start, start + size
                require(offset is not None, f"Mach-O has no ARM64 slice: {path}")
            require(
                data[offset : offset + 4] == b"\xcf\xfa\xed\xfe",
                f"Mach-O is not ARM64: {path}",
            )
            cpu, _, kind, count, command_bytes = struct.unpack_from(
                "<IIIII", data, offset + 4
            )
            require(cpu == ARM64, f"Mach-O has no ARM64 slice: {path}")
            command_start = offset + 32
            command_end = command_start + command_bytes
            require(
                command_end <= limit and count <= command_bytes // 8,
                f"Invalid Mach-O commands: {path}",
            )
            dependencies, rpaths = [], []
            for _ in range(count):
                command, size = struct.unpack_from("<II", data, command_start)
                require(
                    size >= 8 and command_start + size <= command_end,
                    f"Invalid Mach-O command size: {path}",
                )
                if command in DEPENDENCY_COMMANDS or command == 0x8000001C:
                    require(size >= 12, f"Invalid Mach-O path command: {path}")
                    string_offset = struct.unpack_from("<I", data, command_start + 8)[0]
                    require(
                        12 <= string_offset < size,
                        f"Invalid Mach-O path offset: {path}",
                    )
                    raw = data[command_start + string_offset : command_start + size]
                    require(b"\0" in raw, f"Unterminated Mach-O path: {path}")
                    value = raw.split(b"\0", 1)[0].decode("utf-8")
                    (rpaths if command == 0x8000001C else dependencies).append(value)
                command_start += size
            return kind, dependencies, rpaths


def system_path(value):
    normalized = os.path.normpath(value)
    return normalized.startswith(("/usr/lib/", "/System/Library/"))


def expand_path(value, loader, executable):
    for prefix, base in (
        ("@loader_path", loader.parent),
        ("@executable_path", executable.parent),
    ):
        if value == prefix or value.startswith(prefix + "/"):
            return (base / value[len(prefix) :].lstrip("/")).resolve()
    return Path(value).resolve() if value.startswith("/") else None


def validate_application(application):
    root = application.resolve(strict=True)
    require(
        root.is_dir() and root.name == "ChengYing.app",
        "Input must be a ChengYing.app directory.",
    )
    info = plistlib.loads((root / "Contents/Info.plist").read_bytes())
    require(
        info.get("CFBundleIdentifier") == BUNDLE_ID,
        "Unexpected application bundle identifier.",
    )
    require(
        info.get("CFBundleExecutable") == "ChengYing",
        "Unexpected application executable.",
    )
    require(
        info.get("CFBundlePackageType") == "APPL", "Input is not an application bundle."
    )
    require(
        bool(info.get("CFBundleShortVersionString")), "Application version is missing."
    )
    for relative in REQUIRED_EXECUTABLES:
        path = root / relative
        require(
            path.is_file() and os.access(path, os.X_OK),
            f"Missing executable: {relative}",
        )
        require(
            macho_commands(path) is not None,
            f"Executable is not native Mach-O: {relative}",
        )
    for relative in REQUIRED_NOTICES:
        path = root / "Contents/Resources/Legal" / relative
        require(
            path.is_file() and path.stat().st_size > 0,
            f"Missing legal notice: {relative}",
        )

    binaries = {}
    for path in root.rglob("*"):
        if path.is_symlink():
            require(
                not os.path.isabs(os.readlink(path)), f"Absolute bundle symlink: {path}"
            )
            require(
                inside(path.resolve(strict=True), root),
                f"Bundle symlink escapes the application: {path}",
            )
        elif path.is_file():
            commands = macho_commands(path)
            if commands is not None:
                binaries[path] = commands

    main = root / "Contents/MacOS/ChengYing"
    executables = [path for path, commands in binaries.items() if commands[0] == 2]
    visited = set()

    def walk(binary, executable, inherited):
        kind, dependencies, rpaths = binaries[binary]
        del kind
        own_paths = []
        for value in rpaths:
            require(
                not value.startswith("/") or system_path(value),
                f"Absolute non-system runtime search path {value}: {binary}",
            )
            expanded = expand_path(value, binary, executable)
            require(
                expanded is not None,
                f"Unsupported runtime search path {value}: {binary}",
            )
            require(
                inside(expanded, root) or system_path(str(expanded)),
                f"External runtime search path {value}: {binary}",
            )
            own_paths.append(expanded)
        search_paths = tuple(dict.fromkeys(own_paths + list(inherited)))
        key = (binary, executable, search_paths)
        if key in visited:
            return
        visited.add(key)
        for value in dependencies:
            if system_path(value):
                continue
            require(
                not value.startswith("/"),
                f"Absolute non-system dependency {value}: {binary}",
            )
            if value.startswith("@rpath/"):
                candidates = [
                    (directory / value[len("@rpath/") :]).resolve()
                    for directory in search_paths
                ]
                target = next(
                    (candidate for candidate in candidates if candidate in binaries),
                    None,
                )
            else:
                target = expand_path(value, binary, executable)
            require(
                target is not None and inside(target, root),
                f"Unresolved or external dependency {value}: {binary}",
            )
            require(
                target in binaries,
                f"Dependency is not a bundled ARM64 Mach-O: {value}: {binary}",
            )
            walk(target, executable, search_paths)

    for executable in executables:
        walk(executable, executable, ())
    # Runtime-loaded plugins do not always appear in the static executable graph.
    for binary in binaries:
        if any(item[0] == binary for item in visited):
            continue
        enclosing = next(
            (parent for parent in binary.parents if parent.suffix == ".app"), root
        )
        enclosing_info = plistlib.loads(
            (enclosing / "Contents/Info.plist").read_bytes()
        )
        executable = enclosing / "Contents/MacOS" / enclosing_info["CFBundleExecutable"]
        require(
            executable in binaries,
            f"Missing enclosing application executable: {binary}",
        )
        inherited = tuple(
            expand_path(value, executable, executable)
            for value in binaries[executable][2]
        )
        walk(binary, executable, inherited)
    require(main in binaries, "The main executable is missing.")
    run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(root)])
    print(
        f"Verified {len(binaries)} ARM64 Mach-O files and bundled dependency paths.",
        flush=True,
    )
    return info


def snapshot(root):
    result = {}
    for path in root.rglob("*"):
        relative = str(path.relative_to(root))
        if path.is_symlink():
            result[relative] = ("symlink", os.readlink(path))
        elif path.is_file():
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
                    digest.update(chunk)
            result[relative] = ("file", digest.hexdigest(), path.stat().st_mode & 0o777)
        elif path.is_dir():
            result[relative] = ("directory",)
        else:
            raise ValueError(f"Unsupported application filesystem object: {path}")
    return result


def package(application, output):
    application = application.resolve(strict=True)
    output_parent = output.parent.resolve(strict=True)
    output = output_parent / output.name
    checksum = output.with_suffix(output.suffix + ".sha256")
    require(
        output.name.endswith(".dmg") and output.name != ".dmg",
        "Output must have a .dmg filename.",
    )
    require(
        not inside(output, application),
        "Output must not be inside the input application.",
    )
    for target in (output, checksum):
        require(
            not os.path.lexists(target),
            f"Refusing to overwrite an existing output: {target}",
        )
    info = validate_application(application)
    original = snapshot(application)
    work = Path(tempfile.mkdtemp(prefix=".chengying-dmg-", dir=output_parent))
    mount = work / "mounted"
    attach_attempted = False
    try:
        staging = work / "staging"
        staging.mkdir()
        mounted_app = mount / "ChengYing.app"
        run(["ditto", "--noqtn", str(application), str(staging / "ChengYing.app")])
        require(
            snapshot(staging / "ChengYing.app") == original,
            "Application changed while copying to the DMG staging directory.",
        )
        (staging / "Applications").symlink_to("/Applications")
        (staging / "安装说明.txt").write_text(
            "澄影视界 · Apple Silicon 安装\n\n"
            "把 ChengYing.app 拖到 Applications（应用程序）文件夹，再从应用程序打开。\n"
            "适用于 Apple Silicon Mac，包括 M4 Max。无需安装 Homebrew、Python 或 FFmpeg。\n\n"
            "此构建没有 Apple Developer ID 公证。首次打开可能被 macOS 阻止；"
            "请到系统设置 → 隐私与安全性，核对来源后选择“仍要打开”。\n"
            "不要关闭 Gatekeeper，也不需要关闭系统安全保护。\n\n"
            "Install: drag ChengYing.app to Applications, then launch it from Applications.\n"
            "This build is not Developer ID notarized. macOS may require Open Anyway after the first launch attempt.\n",
            encoding="utf-8",
        )
        image = work / "image.dmg"
        print(
            f"Creating read-only Apple Silicon DMG for {info['CFBundleShortVersionString']}...",
            flush=True,
        )
        run(
            [
                "hdiutil",
                "create",
                "-srcfolder",
                str(staging),
                "-volname",
                "ChengYing",
                "-fs",
                "HFS+",
                "-format",
                "UDZO",
                "-imagekey",
                "zlib-level=9",
                str(image),
            ]
        )
        run(["hdiutil", "verify", str(image)])
        image_info = plistlib.loads(
            run(["hdiutil", "imageinfo", "-plist", str(image)], capture=True)
        )
        require(
            image_info.get("Format") == "UDZO",
            "Disk image is not a read-only compressed UDZO image.",
        )
        mount.mkdir()
        attach_attempted = True
        attachment = plistlib.loads(
            run(
                [
                    "hdiutil",
                    "attach",
                    "-readonly",
                    "-nobrowse",
                    "-noautoopen",
                    "-mountpoint",
                    str(mount),
                    "-plist",
                    str(image),
                ],
                capture=True,
            )
        )
        require(
            any(
                item.get("mount-point") == str(mount)
                for item in attachment.get("system-entities", [])
            ),
            "The DMG was not attached at the requested private mount point.",
        )
        require(
            os.readlink(mount / "Applications") == "/Applications",
            "The Applications installation link is incorrect.",
        )
        require(
            snapshot(mounted_app) == original,
            "Mounted application differs from the signed input, including its legal notices.",
        )
        run(
            [
                "codesign",
                "--verify",
                "--deep",
                "--strict",
                "--verbose=2",
                str(mounted_app),
            ]
        )
        run(["hdiutil", "detach", str(mount)])
        attach_attempted = False
        require(
            snapshot(application) == original,
            "Input application changed during packaging.",
        )
        digest = hashlib.sha256()
        with image.open("rb") as stream:
            for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
                digest.update(chunk)
        staged_checksum = work / "image.sha256"
        staged_checksum.write_text(
            f"{digest.hexdigest()}  {output.name}\n", encoding="utf-8"
        )
        # Hard links atomically reject races with another writer; never replace existing files.
        os.link(staged_checksum, checksum)
        try:
            os.link(image, output)
        except BaseException:
            if checksum.stat().st_ino == staged_checksum.stat().st_ino:
                checksum.unlink()
            raise
        print(f"Created {output}\nSHA-256: {checksum}", flush=True)
    finally:
        if attach_attempted:
            result = subprocess.run(["hdiutil", "detach", str(mount)], check=False)
            if result.returncode != 0 and os.path.ismount(mount):
                print(
                    f"Could not detach private DMG mount; preserving temporary directory: {work}",
                    file=sys.stderr,
                )
            else:
                shutil.rmtree(work)
        else:
            shutil.rmtree(work)


def main():
    require(sys.platform == "darwin", "DMG packaging must run on macOS.")
    require(
        len(sys.argv) == 3,
        "Usage: package_dmg.sh <signed/ChengYing.app> <existing-directory/output.dmg>",
    )
    for tool in ("codesign", "ditto", "hdiutil"):
        require(
            shutil.which(tool) is not None, f"Required command is unavailable: {tool}"
        )
    package(Path(sys.argv[1]), Path(sys.argv[2]))


if __name__ == "__main__":

    def interrupted(_number, _frame):
        raise KeyboardInterrupt

    for termination_signal in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(termination_signal, interrupted)
    try:
        main()
    except KeyboardInterrupt:
        print("DMG packaging interrupted.", file=sys.stderr)
        sys.exit(130)
    except (ValueError, OSError, struct.error, subprocess.CalledProcessError) as error:
        print(f"DMG packaging failed: {error}", file=sys.stderr)
        sys.exit(1)
