#!/usr/bin/env python3
"""Run the established native/libmpv harness with isolated subtitle assertions."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
base = root / "Tools/NativeGenericHandoffTests/run.sh"
script = base.read_text()
def replace_checked(before, after, expected=1):
    global script
    if script.count(before) != expected:
        raise SystemExit(f"Unexpected driver landmark count for {before!r}: {script.count(before)} != {expected}")
    script = script.replace(before, after)

replace_checked('repo_root="$(cd "$(dirname "$0")/../.." && pwd)"', f'repo_root="{root}"')
replace_checked("native-generic-handoff", "native-subtitle-drop")
replace_checked('printf \'Artifacts: %s\\n\' "$test_dir"',
                        'printf \'Artifacts: %s\\n\' "$test_dir"\ncp "$0" "$test_dir/driver.sh"')
replace_checked("Tools/NativeGenericHandoffTests/", "Tools/NativeSubtitleDropTests/", expected=7)
replace_checked("Tools/NativeSubtitleDropTests/run.sh", "Tools/NativeSubtitleDropTests/run.py")
replace_checked("NATIVE_GENERIC", "NATIVE_SUBTITLE", expected=3)
replace_checked("generic-tests", "subtitle-tests", expected=2)
replace_checked("Compiled generic fixture", "Compiled subtitle fixture")
replace_checked('"$test_dir/Boundary.swift" > "$test_dir/generated.sha256"',
                        '"$test_dir/Boundary.swift" "$test_dir/driver.sh" > "$test_dir/generated.sha256"')
replace_checked('statuses=("${PIPESTATUS[@]}")\nset -e',
                        'statuses=("${PIPESTATUS[@]}")\nset -e\n'
                        'printf "child=%s tee=%s\\n" "${statuses[0]}" "${statuses[1]}" > "$test_dir/child-status.txt"\n'
                        'if [ -f "$test_dir/fixture.srt" ]; then shasum -a 256 "$test_dir/fixture.srt" "$test_dir/identity.cube" >> "$test_dir/generated.sha256"; fi')
replace_checked('iina/VideoView.swift)', 'iina/VideoView.swift iina/Regex.swift iina/MPVFilter.swift iina/ImageViewer/ImageFileSupport.swift)')
replace_checked('sources=("${swift_sources[@]}"', '''sources=(Tools/NativeGenericHandoffTests/run.sh Tools/NativeGenericHandoffTests/prepare.py
  Tools/NativeSubtitleDropTests/Boundary.swift iina/DraggingDetect.swift iina/Utility.swift iina/Extensions.swift iina/AutoFileMatcher.swift
  iina/ImageViewer/ImageViewerCoordinator.swift "${swift_sources[@]}"''')
driver_dir = Path(tempfile.mkdtemp(prefix="native-subtitle-driver.", dir=root / "build"))
driver = driver_dir / "run.sh"
driver.write_text(script)
print(f"Driver: {driver}", flush=True)
environment = os.environ.copy()
targeted_cases = {"early-invalidation": "retiring", "remove-inventory-gate": "inventory",
                  "busy-mute": "actions", "busy-frame-step": "actions", "busy-screenshot": "actions"}
if environment.get("NATIVE_SUBTITLE_NEGATIVE_CONTROL") in targeted_cases:
    environment.setdefault("NATIVE_SUBTITLE_CASE", targeted_cases[environment["NATIVE_SUBTITLE_NEGATIVE_CONTROL"]])
raise SystemExit(subprocess.run(["/bin/bash", str(driver)], cwd=root, env=environment).returncode)
