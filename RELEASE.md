# CodeReentry local development release

CodeReentry can be built as a local, ad-hoc-signed macOS application for development and
evaluation. This path does not require an Apple Developer ID or notarization credentials.

For the shortest source-evaluation path, run `./scripts/run-source.sh`. It builds,
verifies, and launches the app without creating distributable archives or requiring
XcodeGen. Pass `--install` to stage and verify the local build before placing it in the
current user's `~/Applications` directory. The packaging flow below is intended for
maintainers who need a local DMG.

## Build and package

Requirements: macOS 14 or newer, Xcode, and `xcodegen`.

```bash
cd /path/to/CodeReentry
./scripts/release-local.sh
```

The script regenerates the Xcode project, builds an arm64 Release app, verifies its
bundle metadata, hardened runtime, entitlements, signature, architecture, and icon,
then writes a DMG, ZIP, and SHA-256 file under `dist/`.

Before handing off a package, mount the final DMG and launch the contained app for a
smoke test. Static `codesign` verification does not exercise dyld's library-validation
policy, so confirm that the process remains alive and that no new CodeReentry crash report
appears under `~/Library/Logs/DiagnosticReports`.

The local ad-hoc build uses the legacy-compatible internal file
`DevHub.local-release.entitlements`. Ad-hoc signatures
have no Apple Team ID, so this local-only profile disables library validation in order
to load the embedded, separately signed Sparkle framework. Hardened runtime remains
enabled, `get-task-allow` is rejected by the verification script, and the normal
`DevHub.entitlements` profile keeps library validation enabled.

## Recovery evidence gate

Before describing project re-entry as validated, complete the privacy-safe protocol in
[`docs/reentry-validation.md`](docs/reentry-validation.md). The release check requires
at least ten real attempts across three anonymous project slots and two tools, including
both recent and older sessions. Run `./scripts/reentry-trial.sh summary`; do not claim
the workflow gate passed unless it reports coverage and outcome targets met with zero
cross-project context incidents. Raw trial data stays in ignored `local-data/` and must
never be attached to a release.

## Performance evidence gate

Run the deterministic Release scenario described in
[`docs/performance-baseline.md`](docs/performance-baseline.md):

```bash
./scripts/performance-baseline.sh --scale medium --cycles 10 \
  --idle-seconds 300 --recovery-seconds 10
```

The command must exit successfully against `scripts/performance-budget.json`. Run the
large scale before claiming large-index readiness. Its latest full five-minute result
passes the initial-scan budget with all 20,000 synthetic sessions verified. Generated
samples stay under ignored `local-data/` and must not be attached to a release. Historical
failed controls remain in the baseline so performance improvements can be audited.

## Install

For a durable user-level install built from the current checkout:

```bash
./scripts/run-source.sh --install
```

The installer does not use `sudo`, refuses symbolic links and foreign bundle identifiers,
and restores the previous matching app if placement or final verification fails.

Open the DMG and drag CodeReentry to Applications. Because this personal build is not
notarized, macOS may require the first launch through Finder's **Open** context-menu
action. Do not disable Gatekeeper globally.

CodeReentry requests Automation access only when it opens Terminal for a CLI tool. Project
folders outside the normal user-visible locations may also require Files and Folders
or Full Disk Access in System Settings.

## Public distribution

A public download requires a Developer ID Application certificate,
an Apple development team, notarization credentials, and a real Sparkle feed signed
with an EdDSA key. The app intentionally has no `SUFeedURL` until those external
credentials and a stable HTTPS release host exist; automatic updates stay disabled
instead of pointing at a placeholder feed. Re-sign Sparkle with the same Developer ID
identity as the app and do not use the local-release entitlement profile publicly.
