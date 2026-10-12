#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/rotation-intent-tests.XXXXXX")"
printf 'Artifacts: %s\n' "$test_dir"
git rev-parse HEAD > "$test_dir/base-commit.txt"
printf '%s\n' "${ROTATION_INTENT_SANITIZER:-normal}" > "$test_dir/mode.txt"
sources=(iina/VideoTools/VideoToolsRotationIntent.swift
  iina/Updates/UpdateWorkAdmission.swift iina/VideoTools/VideoToolsModels.swift
  iina/VideoTools/VideoToolsRotationCoordinator.swift)
shasum -a 256 "${sources[@]}" Tools/VideoToolsRotationIntentTests/main.swift \
  Tools/VideoToolsRotationIntentTests/run.sh Tools/VideoToolsRotationIntentTests/mutate.swift \
  Tools/VideoToolsTests/RotationCoordinatorTests.swift \
  > "$test_dir/inputs.sha256"
finish_evidence() {
  original_status=$?
  trap - EXIT
  set +e
  if compgen -G "$test_dir/*.swift" > /dev/null; then
    shasum -a 256 "$test_dir/"*.swift > "$test_dir/negative-sources.sha256"
    generated_status=$?
  else
    generated_status=0
  fi
  shasum -a 256 -c "$test_dir/inputs.sha256" > "$test_dir/source-check.log" 2>&1
  source_status=$?
  if [[ "$original_status" -eq 0 && ( "$source_status" -ne 0 || "$generated_status" -ne 0 ) ]]; then original_status=1; fi
  printf 'Runner exit: %s; source check: %s; generated manifest: %s\n' "$original_status" "$source_status" "$generated_status"
  exit "$original_status"
}
trap finish_evidence EXIT
compiler=(xcrun swiftc -swift-version 5 -parse-as-library)
case "${ROTATION_INTENT_SANITIZER:-}" in
  "") ;;
  address|thread) compiler+=("-sanitize=$ROTATION_INTENT_SANITIZER") ;;
  *) printf 'Unsupported sanitizer\n' >&2; exit 2 ;;
esac
xcrun swiftc -swift-version 5 -parse-as-library -target x86_64-apple-macos10.15 -typecheck \
  "${sources[@]}" Tools/VideoToolsRotationIntentTests/main.swift
"${compiler[@]}" "${sources[@]}" Tools/VideoToolsRotationIntentTests/main.swift \
  -o "$test_dir/intent-tests"
/usr/bin/perl -e 'alarm 30; exec @ARGV' "$test_dir/intent-tests" 2>&1 | tee "$test_dir/results.log"
"${compiler[@]}" "${sources[@]}" Tools/VideoToolsTests/RotationCoordinatorTests.swift \
  -o "$test_dir/coordinator-tests"
/usr/bin/perl -e 'alarm 30; exec @ARGV' "$test_dir/coordinator-tests" 2>&1 | tee "$test_dir/coordinator.log"
/usr/bin/perl -e 'alarm 30; exec @ARGV' "$test_dir/intent-tests" --ownership-probe 2>&1 | tee "$test_dir/ownership.log"
xcrun swift Tools/VideoToolsRotationIntentTests/mutate.swift "$repo_root" "$test_dir"
for mutation in repeated-consumption stale-request; do
  "${compiler[@]}" "$test_dir/$mutation.swift" "${sources[@]:1}" \
    Tools/VideoToolsRotationIntentTests/main.swift -o "$test_dir/$mutation"
  set +e
  /usr/bin/perl -e 'alarm 30; exec @ARGV' "$test_dir/$mutation" --ownership-probe 2>&1 | tee "$test_dir/$mutation.log"
  statuses=("${PIPESTATUS[@]}")
  set -e
  if [[ "${statuses[0]}" -ne 1 || "${statuses[1]}" -ne 0 ]]; then
    printf 'Negative control failed to reject exactly as expected: %s\n' "$mutation" >&2
    exit 1
  fi
  if [[ "$mutation" == repeated-consumption ]]; then
    expected_failure='FAIL: Repeated completion must not replay a submission'
  else
    expected_failure='FAIL: A stale completion must not consume a newer request'
  fi
  rg -Fq "$expected_failure" "$test_dir/$mutation.log"
  printf 'PASS: The %s negative control was rejected\n' "$mutation"
done
