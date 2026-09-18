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
- Do not publish a release unless the user's active request authorizes publication.

## Communication

- Use Chinese for user-facing explanations and summaries.
- Keep code, comments, identifiers, commit messages and log output in English.
