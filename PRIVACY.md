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
