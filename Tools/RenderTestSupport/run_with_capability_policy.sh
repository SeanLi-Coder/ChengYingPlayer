#!/bin/bash
set -euo pipefail

if (( $# < 3 )); then
  echo 'Usage: run_with_capability_policy.sh hardware|software <test-label> <command> [arguments...]' >&2
  exit 2
fi
mode="$1"
label="$2"
shift 2
if [[ "$mode" != hardware && "$mode" != software ]]; then
  echo 'ERROR: A hardware or software test mode is required.' >&2
  exit 2
fi

status=0
"$@" || status=$?
if (( status == 77 )) && [[ "$mode" == software && "${GITHUB_ACTIONS:-}" == true && "${CHENGYING_ALLOW_CI_GL_SKIP:-}" == 1 ]]; then
  printf '::warning::SKIP: %s has no supported CGL 3.2 context on this CI runner. No OpenGL pass is claimed.\n' "$label"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '\n- SKIP: %s — this runner lacks a supported CGL 3.2 context. This is not an OpenGL or hardware-decoding pass; decoder, libmpv, native UI and actual App tests remain separate requirements.\n' "$label" >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
fi
exit "$status"
