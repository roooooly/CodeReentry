# DevHub local development release

DevHub can be built as a local, ad-hoc-signed macOS application for development and
evaluation. This path does not require an Apple Developer ID or notarization credentials.

## Build and package

Requirements: macOS 14 or newer, Xcode, and `xcodegen`.

```bash
cd /path/to/DevHub
./scripts/release-local.sh
```

The script regenerates the Xcode project, builds an arm64 Release app, verifies its
bundle metadata, hardened runtime, entitlements, signature, architecture, and icon,
then writes a DMG, ZIP, and SHA-256 file under `dist/`.

Before handing off a package, mount the final DMG and launch the contained app for a
smoke test. Static `codesign` verification does not exercise dyld's library-validation
policy, so confirm that the process remains alive and that no new DevHub crash report
appears under `~/Library/Logs/DiagnosticReports`.

The local ad-hoc build uses `DevHub.local-release.entitlements`. Ad-hoc signatures
have no Apple Team ID, so this local-only profile disables library validation in order
to load the embedded, separately signed Sparkle framework. Hardened runtime remains
enabled, `get-task-allow` is rejected by the verification script, and the normal
`DevHub.entitlements` profile keeps library validation enabled.

## Install

Open the DMG and drag DevHub to Applications. Because this personal build is not
notarized, macOS may require the first launch through Finder's **Open** context-menu
action. Do not disable Gatekeeper globally.

DevHub requests Automation access only when it opens Terminal for a CLI tool. Project
folders outside the normal user-visible locations may also require Files and Folders
or Full Disk Access in System Settings.

## Public distribution

A public download requires a Developer ID Application certificate,
an Apple development team, notarization credentials, and a real Sparkle feed signed
with an EdDSA key. The app intentionally has no `SUFeedURL` until those external
credentials and a stable HTTPS release host exist; automatic updates stay disabled
instead of pointing at a placeholder feed. Re-sign Sparkle with the same Developer ID
identity as the app and do not use the local-release entitlement profile publicly.
