"""Build a background macOS application with an intact stdio protocol."""

import json
import os
from pathlib import Path

from PyInstaller.building.api import COLLECT, EXE, PYZ
from PyInstaller.building.build_main import Analysis
from PyInstaller.building.osx import BUNDLE
from PyInstaller.utils.hooks import collect_all, copy_metadata

source = Path(os.environ["CHENGYING_HELPER_SOURCE_DIR"])
vendor = Path(os.environ["CHENGYING_HELPER_VENDOR_DIR"])
legal = Path(os.environ["CHENGYING_HELPER_LEGAL_DIR"])
identity = os.environ["CHENGYING_HELPER_SIGNING_IDENTITY"]
architecture = os.environ["CHENGYING_HELPER_TARGET_ARCH"]

data_files = [
    (str(vendor), "vendor/rednote"),
    (str(vendor / "app/static"), "app/static"),
    (str(source / "static"), "static"),
    (str(source / "runtime-artifacts.json"), "."),
    (str(source / "runtime-sources.json"), "."),
    (str(source / "upstream-manifest.json"), "."),
    (str(legal), "Legal"),
]
binaries = []
hiddenimports = ["bundle_smoke"]
for package in (
    "app",
    "yt_dlp",
    "yt_dlp_ejs",
    "playwright",
    "uvicorn",
    "fastapi",
    "starlette",
    "pydantic",
    "pydantic_core",
    "requests",
    "urllib3",
    "websockets",
    "Cryptodome",
    "certifi",
    "truststore",
    "mutagen",
):
    package_data, package_binaries, package_imports = collect_all(package)
    data_files += package_data
    binaries += package_binaries
    hiddenimports += package_imports
for package in json.loads((source / "runtime-artifacts.json").read_text())["artifacts"]:
    data_files += copy_metadata(package["name"])

analysis = Analysis(
    [str(source / "helper.py")],
    pathex=[str(vendor), str(source)],
    binaries=binaries,
    datas=data_files,
    hiddenimports=hiddenimports,
)
archive = PYZ(analysis.pure)
executable = EXE(
    archive,
    analysis.scripts,
    [],
    exclude_binaries=True,
    name="chengying-download-center-helper",
    console=True,
    argv_emulation=False,
    target_arch=architecture,
    codesign_identity=identity,
    entitlements_file=str(source / "runtime-entitlements.plist"),
)
collection = COLLECT(
    executable,
    analysis.binaries,
    analysis.datas,
    name="chengying-download-center-helper",
)
# BUNDLE relocates Mach-O code to Frameworks and data to Resources, preserving
# package-relative paths with cross-links. Its Node driver is shared with EJS.
application = BUNDLE(
    collection,
    name="DownloadCenter.app",
    bundle_identifier="io.github.SeanLi-Coder.ChengYingPlayer.DownloadCenter",
    info_plist={
        "LSBackgroundOnly": True,
        "LSUIElement": True,
        "LSMinimumSystemVersion": "13.5",
    },
)
