# Changelog

All notable user-facing and repository changes are recorded here. CodeReentry has not yet
published a signed public binary.

## Unreleased

- Add an explicitly triggered, fully local recovery timer and evidence dashboard that
  measures real project/session/context recovery against the published gate.
- Persist only a strict owner-only anonymous CSV without project identifiers, names,
  paths, session IDs, prompts, messages, or notes; unfinished timers remain memory-only.
- Extend the shared native/CLI evidence schema to Gemini CLI and GitHub Copilot CLI.
- Preserve an owner-only, one-time launcher when macOS blocks Terminal Automation and
  offer a shell-quoted path command that users can paste into Terminal without putting
  session IDs, project memory, or environment values on the clipboard.
- Delete a declined launcher and its managed memory-injection companion immediately;
  executed launchers still remove themselves and stale files retain the 24-hour bound.
- Serialize streaming pipe drains with process termination so short-lived operations do
  not lose their final stdout or stderr lines.
- Add a verified `--install` path for source evaluators that stages a local build under
  `~/Applications`, refuses symlinks and foreign bundles, and restores the prior copy if
  installation fails.

## 0.5.0 - 2026-08-21

- Add an isolated demo that lets cautious users inspect the complete recovery flow with
  synthetic, disposable data before granting access to local projects or sessions.
- Keep demo mode outside the normal database and preferences, disable local readers,
  usage scans, plugins, MCP servers, Git subprocesses, and external tool launches, and
  remove its temporary workspace when the app exits.
- Add bounded GitHub Copilot CLI session discovery, conversation viewing, and exact-ID
  resume from documented `session-state` events while excluding reasoning, system
  prompts, streaming deltas, subagents, and symbolic links.
- Show the explicit scan, bounded conversation inspection, and original-tool continue
  path in both repository languages with synthetic snapshots.
- Prevent a transient session-detail loading state from replacing already available
  conversation content.

## 0.4.0 - 2026-08-21

- Add bounded, read-only Gemini CLI session discovery, on-demand conversation viewing,
  and exact resume with the full session UUID.
- Resolve Gemini projects from the official ownership marker or project registry, apply
  rewind and checkpoint records, and keep subagent sessions out of the resumable index.
- Add Gemini CLI once to existing tool catalogs without restoring unrelated tools a user
  previously removed; later user deletion remains respected.

## 0.3.2 - 2026-08-21

- Make project cards choose the latest session that can actually resume instead of the
  latest metadata row regardless of local readiness.
- Fall back to the registered project root when a historical session subdirectory moved,
  and explain missing project or tool prerequisites without opening a doomed Terminal command.
- Use the persisted tool executable, environment, and Keychain-backed values consistently
  when resuming from the project overview, project Sessions tab, or global session index.

## 0.3.1 - 2026-08-21

- Add a session-first onboarding path that infers recent project roots from bounded local
  cwd metadata, requires confirmation, and links cached unclassified sessions immediately.
- Preserve manual folder setup and explicit, on-demand scanning as the privacy-safe fallback.
- Bound MCP timeout cleanup even when a hostile descendant inherits a transport pipe and
  ignores graceful termination.

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
