# Changelog

All notable user-facing and repository changes are recorded here. CodeReentry has not yet
published a signed public binary.

## Unreleased

## 0.3.1 - 2026-08-21

- Add a session-first onboarding path that infers recent project roots from bounded local
  cwd metadata, requires confirmation, and links cached unclassified sessions immediately.
- Preserve manual folder setup and explicit, on-demand scanning as the privacy-safe fallback.

## 0.3.0 - 2026-08-21

- Rename the public product and repository from DevHub to CodeReentry after a documented
  collision check.
- Keep the existing bundle identifier, `Application Support/DevHub` data directory,
  `.devhub` project marker, Keychain semantics, script variables, and Swift modules so
  existing source-beta data remains available without migration.
- Ship the visible application as `CodeReentry.app` while retaining the internal DevHub
  Xcode target and module names.
- Refresh the English, Simplified Chinese, release, roadmap, and social-preview surfaces
  for the new public name.

## 0.2.0 - 2026-08-21

- Add bounded, read-only OpenCode v1.18.19 session discovery and exact-session resume.
- Put an explicit local-session scan on the project overview and at the end of onboarding.
- Add a one-command, CI-verified source build and launch path that does not require XcodeGen.
- Record session-summary provenance and require confirmation before sending an outdated or unverifiable summary.
- Add a local, privacy-safe re-entry trial recorder and an explicit evidence gate for recovery claims.
- Add reproducible small/medium/large Release performance fixtures, sampling, budgets,
  and a published baseline that retains failed controls alongside the passing formal runs.
- Reduce large incremental-index refresh work to a cached source-file lookup and bound
  the global session page to explicit 500-row metadata batches.
- Require Sparkle 2.9.6 or newer for upstream security fixes.
- Clarify the project-recovery focus and current compatibility boundaries.
- Add separate English and Simplified Chinese repository documentation.
- Add GitHub community templates, continuous integration, and privacy checks.
- Add a deterministic social-preview asset built from synthetic fixture data.

## 0.1.0 - 2026-08-15

- Initial open-source source release under the MIT License.
- Native SwiftUI project workspace, local session index, project memory, usage views,
  tool launchers, settings, and explicit plugin permission boundaries.
