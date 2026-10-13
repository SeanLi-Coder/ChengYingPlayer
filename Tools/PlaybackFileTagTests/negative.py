#!/usr/bin/env python3
"""Run precise broken-source controls against the same filesystem assertions."""

import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["remove-color", "skip-conflict", "skip-readback"])
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    source = repo / "iina/PlaybackFileTags.swift"
    metadata = repo / "iina/PlaylistFileMetadata.swift"
    tests = repo / "Tools/PlaybackFileTagTests/main.swift"
    before = {str(path.relative_to(repo)): digest(path) for path in [source, metadata, tests]}
    workspace = Path(tempfile.mkdtemp(prefix="playback-file-tags-control.", dir=repo / "build"))
    print(f"Control evidence: {workspace}", flush=True)
    text = source.read_text()
    if args.mode == "remove-color":
        old = "tags.removeAll { $0 == tag }"
        new = 'tags.removeAll { $0 == tag || (tag.name == "Custom green" && $0.colorIndex == tag.colorIndex) }'
        expected_replacements = 1
        expected_failures = {"unselected same-color custom tag preserved"}
    elif args.mode == "skip-conflict":
        old = "guard try readAttribute(snapshot.descriptor) == snapshot.attribute else { throw TagError.changed }"
        new = "// Negative control: ignore observed concurrent tag changes."
        expected_replacements = 3
        expected_failures = {
            "concurrent Finder attribute edit rejected", "concurrent Finder edit not overwritten",
            "late attribute conflict before syscall rejected", "late external tag preserved",
        }
    else:
        old = "guard try readAttribute(snapshot.descriptor) == data else { throw TagError.writeUnverified }"
        new = "// Negative control: ignore the actual written attribute."
        expected_replacements = 1
        expected_failures = {"post-write divergence not falsely successful"}
    if text.count(old) != expected_replacements:
        raise RuntimeError("Negative-control anchor count changed")
    generated = workspace / "PlaybackFileTags.swift"
    generated.write_text(text.replace(old, new))
    binary = workspace / "verify"
    subprocess.run(["xcrun", "swiftc", "-DPLAYBACK_FILE_TAG_TESTING", str(generated), str(metadata), str(tests),
                    "-o", str(binary)], check=True, timeout=60)
    result = subprocess.run([str(binary), str(workspace / "fixtures")], capture_output=True, text=True, timeout=60)
    (workspace / "result.txt").write_text(result.stdout)
    (workspace / "stderr.txt").write_text(result.stderr)
    observed = {line[5:] for line in result.stdout.splitlines() if line.startswith("FAIL ")}
    summary = re.findall(r"SUMMARY checks=(\d+) failures=(\d+)", result.stdout)
    after = {str(path.relative_to(repo)): digest(path) for path in [source, metadata, tests]}
    # Removing all same-color tags also shortens the later removal loop by one tag,
    # whose four callback/activity assertions disappear. All other labels remain.
    expected_count = 332 if args.mode == "remove-color" else 336
    passed = (result.returncode == 1 and observed == expected_failures and
              summary == [(str(expected_count), str(len(expected_failures)))] and before == after and
              not result.stderr)
    report = {"mode": args.mode, "passed": passed, "child_exit_code": result.returncode,
              "expected_failures": sorted(expected_failures), "observed_failures": sorted(observed),
              "summary": summary, "source_hashes_before": before, "source_hashes_after": after,
              "generated_sha256": digest(generated)}
    (workspace / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report[key] for key in ["mode", "passed", "child_exit_code", "observed_failures", "summary"]}))
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
