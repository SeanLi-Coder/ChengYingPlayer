"""Fail closed when a benchmark's execution or identity evidence is incomplete."""
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def manifest(path):
    entries = {}
    for line in path.read_text().splitlines():
        digest, separator, name = line.partition("  ")
        if not separator or len(digest) != 64 or any(ch not in "0123456789abcdef" for ch in digest):
            raise ValueError("Malformed SHA-256 identity manifest")
        item = Path(name)
        if not item.is_absolute():
            item = ROOT / item
        item = item.resolve()
        # Manifests are produced by this local runner, not by downloaded media.
        # Verify real bytes again; a successful old log is not sufficient.
        value = hashlib.sha256()
        with item.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                value.update(block)
        if value.hexdigest() != digest:
            raise ValueError("Recorded test input or output identity changed")
        if str(item) in entries and entries[str(item)] != digest:
            raise ValueError("Conflicting manifest identities")
        entries[str(item)] = digest
    if not entries:
        raise ValueError("Empty identity manifest")
    return entries


def validate(directory, expected_child=0):
    state = json.loads((directory / "evidence-status.json").read_text())
    expected = {"version": 2, "child": expected_child, "tee": 0,
                "source": 0, "generated": 0, "dependencies": 0, "results": 0, "runner": expected_child}
    if state != expected or any(type(value) is not int for value in state.values()):
        raise ValueError("Runner evidence contains a missing or failed execution/identity gate")
    if (directory / "exit-status.txt").read_text().strip() != str(expected_child):
        raise ValueError("Runner exit status differs from the expected child result")
    before = directory / "source-before.sha256"
    after = directory / "source-after.sha256"
    if before.read_bytes() != after.read_bytes() or (directory / "source-diff.txt").read_bytes():
        raise ValueError("Source changed during execution")
    manifest(before)
    manifest(directory / "generated.sha256")
    results = manifest(directory / "results.sha256")
    if set(results) != {str(directory.resolve() / name) for name in ("report.json", "results.log")}:
        raise ValueError("Result identities must cover exactly the report and child log")
    dependencies = manifest(directory / "dependency-sha256.txt")
    runtime = json.loads((directory / "dependency-runtime.json").read_text())
    dependency_root = Path((directory / "dependency-root.txt").read_text().strip())
    if runtime.get("verified") is not True or runtime.get("dependencies") != str(dependency_root):
        raise ValueError("Dynamic runtime closure was not verified for these dependencies")
    libraries = runtime.get("library_sha256")
    if not isinstance(libraries, dict) or not libraries:
        raise ValueError("Missing dynamic runtime library identities")
    for name, digest in libraries.items():
        if Path(name).name != name or dependencies.get(str((dependency_root / "lib" / name).resolve())) != digest:
            raise ValueError("Runtime library identity differs from the validated manifest")
    return state
