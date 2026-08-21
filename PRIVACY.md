# Privacy

CodeReentry is a local resource manager. Its purpose requires access to files and metadata
that may be private, so the boundary should be explicit.

## Data CodeReentry can read

Depending on enabled features and user configuration, CodeReentry can read:

- directories beneath the configured project root;
- Git metadata for registered projects;
- supported tools' local session indexes and history files;
- project memory files selected by the user;
- local tool availability and usage metadata;
- subscription and platform-account records entered in CodeReentry.

Indexing is metadata-first. Conversation bodies are not required to build the global
session list and are loaded on demand when a conversation is opened.

## Data CodeReentry writes

CodeReentry writes its SwiftData store, preferences, indexes, and caches to the current macOS
user's application-support locations. Secret values are stored in macOS Keychain. A
backup contains secret key names only, never secret values.

When the user explicitly selects **Measure This Recovery** and later submits a result,
CodeReentry writes an owner-only (`0600`) CSV under
`~/Library/Application Support/CodeReentry/reentry-trials.csv`. Its fixed schema contains
only an anonymous derived project slot, tool, coarse session age, durations, outcome,
coarse repeated-background reduction, a cross-project flag, and a failure category. It
does not contain project identifiers, names, paths, session IDs, prompts, messages, source
content, or free-form notes. An unfinished timer is memory-only. The app has no feature to
upload this evidence. The Recovery Evidence page can permanently delete the evidence CSV
and any unfinished timer without deleting projects, sessions, source files, or unrelated
application-support data.

Launching a CLI creates an owner-only (`0700`) temporary script under CodeReentry's cache.
The script can contain shell-quoted project paths and launch environment values, so it
deletes itself after execution. If macOS blocks Terminal Automation, the app offers a
manual fallback whose clipboard text contains only the shell-quoted launcher path. Choosing
Discard removes the launcher and its managed memory-injection file immediately. Abandoned
launcher and injection files are removed when they become more than 24 hours old.

## Network behavior

CodeReentry has no telemetry or analytics service. Network access can still occur when the
user explicitly:

- opens a platform or tool website;
- connects an MCP server or enables a plugin that uses the network;
- checks for updates in a future build configured with a real Sparkle feed.

The repository's default app configuration does not include an update-feed URL.

## Logs and exports

Diagnostic export is user initiated. It is limited to recent entries from CodeReentry's own
logging subsystem and filters common token, authorization, password, and private-key
patterns. Review an exported file before sharing it.

## Repository hygiene

The repository ignores local databases, JSONL histories, logs, build artifacts,
signing material, local settings, and dependency caches. `scripts/privacy-audit.sh`
adds a second check for user-specific paths, identifiers, and credential-shaped text.

If you find a privacy or security issue, follow [SECURITY.md](SECURITY.md) rather than
posting sensitive details in a public issue.
