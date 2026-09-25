# Cross-machine collaboration

- Before changing this project, read `docs/AI_COLLABORATION.md`. It contains the
  shared handoff for Codex and the user's Qwen agent on an Apple Silicon Mac.
  The user switched the M4 Max collaborator from GLM to Qwen on 2026-09-25.
  Preserve historical GLM attribution and filenames; they are not current task
  assignments. `QWEN.md` is a pointer to these shared instructions.
- For downloader changes, also read `Tools/DownloaderHelper/UPSTREAM.md` before
  editing the vendored engine or its integrity manifest.
- For the Kuaishou review follow-up, read
  `docs/handoffs/2026-09-25-glm-fix-guidance.md`. It records reproducible findings
  against commit `7372e9cb` and the required regression evidence; recheck later
  commits before assuming a finding remains open.
- Start by checking the branch, commit and working tree. Preserve other agents'
  uncommitted work; use a separate topic branch for concurrent implementation.
- The standalone Kuaishou test/download kits were discontinued at the user's
  request on 2026-09-25. Do not recreate or depend on them unless requested again.
  Improve the existing player download center and retain its regression tests.
- Treat dated handoff findings as evidence, not proof of current behavior or a
  new instruction to implement every listed follow-up. Confirm the user's scope.
- Hand off the commit or PR, changed files, exact test commands and outcomes,
  real-site verification limits, and remaining work. Never commit cookies, private
  browser profiles, credentials, downloaded personal media or employee emails.
- Documentation-only handoffs do not require a new player version or release tag.
  Player releases must still satisfy every requirement below.

# Player release requirements

- Every future stable player release must preserve working automatic updates. This
  is a standing user requirement, not an optional feature for an individual version.
- Keep the existing bundle identifier, stable feed URL, and Ed25519 signing identity.
  Do not rotate the public key, disable signature checks, or reset explicit user
  opt-outs just to ship a new version. Any identity migration requires a separately
  designed and verified bridge for already installed applications.
- Increment both the marketing version and build number. Include the signed
  `appcast.xml` and the exact immutable Apple Silicon DMG in every stable release.
  Preserve the corresponding source, licenses, checksums and source manifest.
- Run the update policy, native updater and signed-installation regression tests.
  Verify the new feed with the previous stable version's public key before publishing.
- Upload and verify all six required assets in a stable draft before publication.
  Retry missing uploads without replacing existing assets; fail on conflicting
  remote bytes. Never overwrite an already published release to repair a version;
  prepare a newer release instead.
- A release is not fully verified until an unauthenticated request confirms the
  public latest version, the exact installed-app feed URL and the downloaded DMG's
  complete size and SHA-256 digest.
  A local build, Git tag, draft release or authenticated download alone is not proof
  that installed players can update. Report failures and unverified states accurately.
- Keep automatic downloads visible and defer replacement while playback, editing,
  exports, downloads or other protected work remains active. Preserve media, model
  files, user preferences and download history across updates.
- The user has given standing authorization to automatically publish future player
  changes after implementation and verification. Continue through versioning,
  commit/tag/push, stable release publication and public update delivery checks
  without asking for a separate release confirmation on every change.
- This authorization applies only to this player repository and its existing
  release workflow. Preserve any later user request to defer publication. Do not
  bypass failed checks, publish incomplete builds, access secrets outside the
  established signing workflow, or expand publication to unrelated projects.
- If release verification fails or required access is unavailable, keep the
  incomplete release unpublished, report the blocker accurately, and continue
  safe fixes or retries within the requested scope.

## Communication

- Use Chinese for user-facing explanations and summaries.
- Keep code, comments, identifiers, commit messages and log output in English.
