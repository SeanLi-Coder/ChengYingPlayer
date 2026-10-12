#!/usr/bin/env python3
"""Test the real tools-menu gate without launching an application bundle."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def extract(source, declaration):
    if source.count(declaration) != 1:
        raise RuntimeError(f"Expected one declaration: {declaration}")
    start = source.index(declaration)
    opening = source.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        if source[cursor] == "{":
            depth += 1
        elif source[cursor] == "}":
            depth -= 1
        cursor += 1
    return source[start:cursor]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--negative-control", choices=["old-guard"])
    parser.add_argument("--sanitizer", choices=["address", "thread"])
    args = parser.parse_args()
    sources = [ROOT / "iina/MainMenuActions.swift", ROOT / "iina/PlaybackInfo.swift",
               ROOT / "iina/PlayerCore.swift", ROOT / "iina/PlayerState.swift",
               HERE / "run.py", HERE / "main.swift"]
    before = {str(path.relative_to(ROOT)): digest(path) for path in sources}
    work = Path(tempfile.mkdtemp(prefix="native-video-tools-menu-tests.", dir=ROOT / "build"))
    print(f"Evidence: {work}", flush=True)
    (work / "source.sha256").write_text("".join(f"{value}  {key}\n" for key, value in before.items()))
    menu = sources[0].read_text()
    info = sources[1].read_text()
    core = sources[2].read_text()
    gate = extract(menu, "private var canShowVideoTools: Bool")
    if args.negative_control == "old-guard":
        old = "          hasSupportedVideo,"
        if gate.count(old) != 1:
            raise RuntimeError("The old-guard mutation no longer matches exactly")
        gate = gate.replace(old, "          player.info.isAudio == .notAudio,")
        # Avoid an unused-binding compile failure; the behavioral gate alone is
        # the negative control, not compiler rejection of a dead local variable.
        gate = gate.replace("    guard !player.isInMiniPlayer,", "    _ = hasSupportedVideo\n    guard !player.isInMiniPlayer,")
    generated = """import AppKit
extension InfoBoundary {
""" + extract(info, "enum MediaIsAudioStatus {") + "\n" + extract(info, "var isAudio: MediaIsAudioStatus {") + """
}
extension PlayerBoundary {
""" + extract(core, "var nativeInitialPlaybackPending: Bool {") + """
}
final class MenuUnderTest: NSResponder {
  let player: PlayerBoundary
  init(_ player: PlayerBoundary) { self.player = player; super.init() }
  required init?(coder: NSCoder) { fatalError("No nib is used in this boundary test") }
  @objc func menuDeleteCurrentFile(_ sender: NSMenuItem) { fatalError("Out of scope") }
  @objc func menuShowCurrentFileInFinder(_ sender: NSMenuItem) { fatalError("Out of scope") }
""" + gate + "\n" + extract(menu, "@objc func menuShowVideoTools(") + "\n" + extract(menu, "func validateMenuItem(") + "\n}\n"
    production = work / "Production.swift"
    production.write_text(generated)
    fixture = work / "existence-fixture.mp4"
    fixture.write_bytes(b"Not decoded: tools-menu local-file existence fixture.\n")
    generated_before = {path.name: digest(path) for path in [production, fixture]}
    (work / "generated.sha256").write_text("".join(f"{value}  {key}\n" for key, value in generated_before.items()))
    executable = work / "MenuTests"
    command = ["xcrun", "swiftc", "-warnings-as-errors"]
    if args.sanitizer:
        command.append(f"-sanitize={args.sanitizer}")
    command += [str(production), str(ROOT / "iina/PlayerState.swift"), str(HERE / "main.swift"), "-o", str(executable)]
    with (work / "compile.log").open("w") as log:
        compiled = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=90)
    if compiled.returncode:
        print((work / "compile.log").read_text())
        return compiled.returncode
    result = subprocess.run([str(executable), str(fixture)], capture_output=True, text=True, timeout=20)
    (work / "results.log").write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr, end="")
    after = {str(path.relative_to(ROOT)): digest(path) for path in sources}
    generated_after = {path.name: digest(path) for path in [production, fixture]}
    unchanged = before == after and generated_before == generated_after
    (work / "source-validation.log").write_text(f"source_unchanged={before == after}\ngenerated_unchanged={generated_before == generated_after}\n")
    (work / "summary.json").write_text(json.dumps({
        "negative_control": args.negative_control, "sanitizer": args.sanitizer,
        "returncode": result.returncode, "sources_unchanged": unchanged,
        "full_app_executed": False,
    }, indent=2) + "\n")
    if not unchanged:
        print("FAIL: Source or generated inputs changed during the run", file=sys.stderr)
        return 1
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
