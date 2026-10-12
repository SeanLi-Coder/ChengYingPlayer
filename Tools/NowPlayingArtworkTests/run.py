#!/usr/bin/env python3
"""Test actual artwork coordination with controlled cover/Quick Look boundaries."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def method(source, name):
    start = source.index("  private func " + name + "(")
    end = source.index("\n  }", start) + len("\n  }")
    return source[start:end]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sanitize", choices=["address", "thread"])
    parser.add_argument("--negative-control", action="store_true")
    args = parser.parse_args()
    source = (ROOT / "iina/NowPlayingInfoManager.swift").read_text()
    fields = source[source.index("  private let artworkQueue:"):
                    source.index("  /// Whether a Now Playing session is active.")]
    start = source.index("  enum ArtworkKind:")
    kinds = source[start:source.index("\n  }", start) + len("\n  }")]
    methods = [method(source, name) for name in ["discardArtwork", "artworkUpdateComplete"]]
    update_source = (HERE / "LegacyUpdateArtwork.swift.txt").read_text() if args.negative_control else source
    methods.append(method(update_source, "updateArtwork"))
    generated = "import Foundation\nfinal class NowPlayingInfoManager: ArtworkBoundary {\n"
    generated += fields + "\n" + kinds + "\n" + "\n".join(methods) + "\n}\n"
    generated = generated.replace("private ", "")
    with tempfile.TemporaryDirectory(prefix="chengying-artwork-") as directory:
        work = Path(directory)
        production = work / "Production.swift"
        production.write_text(generated)
        executable = work / "ArtworkTests"
        command = ["xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors", "-o", str(executable)]
        if args.sanitize:
            command.append("-sanitize=" + args.sanitize)
        command += [str(ROOT / "iina/Atomic.swift"), str(ROOT / "iina/Lock.swift"),
                    str(HERE / "Boundary.swift"), str(HERE / "main.swift"), str(production)]
        subprocess.run(command, check=True, timeout=90)
        if args.negative_control:
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
            expected = "FAIL: Stale worker cannot consume the next media retry budget"
            if result.returncode != 1 or expected not in result.stderr:
                raise RuntimeError("Legacy negative control missed the required invariant: " + result.stderr)
            print("PASS: Exact legacy method consumes a discarded media retry budget")
        else:
            subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == "__main__":
    main()
