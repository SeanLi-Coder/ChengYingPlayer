"""Generate a reviewed subtitle asset lock from official metadata and a pip report.

This developer-only tool emits JSON to stdout. It never downloads model weights.
The application uses only the resulting bundled lock, never this discovery logic.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import ssl
import sys
import urllib.parse
import urllib.request
from pathlib import Path


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "ChengYingAssetLock/1"})
    with urllib.request.urlopen(request, timeout=90, context=ssl.create_default_context()) as response:
        return response.read()


def model(identifier: str, name: str, repository: str) -> dict:
    metadata = json.loads(fetch(f"https://huggingface.co/api/models/{repository}?blobs=true"))
    revision = metadata["sha"]
    artifacts = []
    for item in metadata["siblings"]:
        filename = item["rfilename"]
        if "/" in filename or filename.startswith("."):
            continue
        if not (filename.endswith((".json", ".safetensors", ".txt", ".model", ".jinja"))
                or filename in {"LICENSE", "LICENSE.txt", "NOTICE"}):
            continue
        url = f"https://huggingface.co/{repository}/resolve/{revision}/{urllib.parse.quote(filename)}"
        lfs = item.get("lfs")
        if lfs:
            digest, size = lfs["sha256"], lfs["size"]
        else:
            data = fetch(url)
            digest, size = hashlib.sha256(data).hexdigest(), len(data)
        artifacts.append({"id": f"{identifier}/{filename}", "path": f"models/{identifier}/{filename}",
                          "url": url, "size": size, "sha256": digest})
    if not any(item["path"].endswith(".safetensors") for item in artifacts):
        raise ValueError(f"No safetensors weights found for {repository}")
    # The Hy-MT2 card tag differs from its controlling LICENSE.txt. Preserve the
    # reviewed license rather than treating a hosting-site tag as authoritative.
    license_name = "Tencent HY Community License" if identifier == "translator" else "apache-2.0"
    license_url = (f"https://huggingface.co/{repository}/blob/{revision}/LICENSE.txt"
                   if identifier == "translator" else "https://www.apache.org/licenses/LICENSE-2.0")
    return {"id": identifier, "name": name, "repository": repository, "revision": revision,
            "directory": f"models/{identifier}", "license": license_name, "license_url": license_url,
            "artifacts": artifacts}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pip-report", type=Path, required=True)
    args = parser.parse_args()
    report = json.loads(args.pip_report.read_text())
    wheels, requirements = [], []
    for item in report["install"]:
        metadata, download = item["metadata"], item["download_info"]
        name, version = metadata["name"], metadata["version"]
        url = download["url"]
        filename = urllib.parse.unquote(urllib.parse.urlparse(url).path.rsplit("/", 1)[-1])
        if not filename.endswith(".whl") or urllib.parse.urlparse(url).hostname != "files.pythonhosted.org":
            raise ValueError(f"Expected an official PyPI wheel: {filename}")
        digest = download["archive_info"]["hashes"]["sha256"]
        pypi = json.loads(fetch(f"https://pypi.org/pypi/{urllib.parse.quote(name)}/{version}/json"))
        published = next(file for file in pypi["urls"] if file["filename"] == filename)
        if published["digests"]["sha256"] != digest:
            raise ValueError(f"Wheel digest mismatch: {filename}")
        wheels.append({"id": f"wheel/{name}", "path": f"wheels/{filename}", "url": url,
                       "size": published["size"], "sha256": digest})
        requirements.append(f"{name}=={version} --hash=sha256:{digest}")
    result = {
        "schema_version": 1,
        "runtime": {
            "id": "chengying-subtitles-macos14-arm64-py313-v1",
            "python_executable": "python/bin/python3",
            "archive": {
                "id": "runtime/python", "path": "downloads/python.tar.gz",
                "url": "https://github.com/astral-sh/python-build-standalone/releases/download/20260901/"
                       "cpython-3.13.15%2B20260901-aarch64-apple-darwin-install_only.tar.gz",
                "size": 25293188,
                "sha256": "b9054a9d3d54f4cb5573d44907fddb29874b08909bde73f29f2868cf872223ee",
            },
            "wheels": wheels, "requirements": requirements,
        },
        "models": [
            model("asr", "Qwen3-ASR 1.7B BF16", "Qwen/Qwen3-ASR-1.7B-hf"),
            model("aligner", "Qwen3-ForcedAligner 0.6B BF16", "Qwen/Qwen3-ForcedAligner-0.6B-hf"),
            model("translator", "Hy-MT2 30B-A3B BF16", "tencent/Hy-MT2-30B-A3B"),
        ],
    }
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    print()


if __name__ == "__main__":
    main()
