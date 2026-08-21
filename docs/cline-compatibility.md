# Cline compatibility boundary

CodeReentry's Cline integration is pinned to the upstream repository tag **v4.1.11** at
commit [`9e0015b78b97d89b01b3b6dfa6e8a8a68aeb8d97`](https://github.com/cline/cline/tree/9e0015b78b97d89b01b3b6dfa6e8a8a68aeb8d97).
That source contains Cline CLI **v3.0.56**. The implementation is read-only and treats
Cline's database, manifests, and message documents as tool-owned sources of truth.

The verified upstream contracts are:

- [`sdk/packages/shared/src/storage/paths.ts`](https://github.com/cline/cline/blob/9e0015b78b97d89b01b3b6dfa6e8a8a68aeb8d97/sdk/packages/shared/src/storage/paths.ts)
  resolves the default `~/.cline/data` tree and the `CLINE_DIR`, `CLINE_DATA_DIR`,
  `CLINE_DB_DATA_DIR`, and `CLINE_SESSION_DATA_DIR` overrides;
- [`sdk/packages/shared/src/db/sqlite-db.ts`](https://github.com/cline/cline/blob/9e0015b78b97d89b01b3b6dfa6e8a8a68aeb8d97/sdk/packages/shared/src/db/sqlite-db.ts)
  defines the `sessions` table, including root/subagent lineage, project paths, prompts,
  metadata, message paths, and ISO-8601 timestamps;
- [`sdk/packages/core/src/services/storage/sqlite-session-store.ts`](https://github.com/cline/cline/blob/9e0015b78b97d89b01b3b6dfa6e8a8a68aeb8d97/sdk/packages/core/src/services/storage/sqlite-session-store.ts)
  places that table in `sessions.db` under the database data directory;
- [`sdk/packages/core/src/session/models/session-manifest.ts`](https://github.com/cline/cline/blob/9e0015b78b97d89b01b3b6dfa6e8a8a68aeb8d97/sdk/packages/core/src/session/models/session-manifest.ts)
  defines the version-1 per-session manifest fallback;
- [`sdk/packages/core/src/runtime/host/runtime-host-support.ts`](https://github.com/cline/cline/blob/9e0015b78b97d89b01b3b6dfa6e8a8a68aeb8d97/sdk/packages/core/src/runtime/host/runtime-host-support.ts)
  reads either a message array or an envelope containing `messages`;
- [`sdk/packages/core/src/runtime/host/history.ts`](https://github.com/cline/cline/blob/9e0015b78b97d89b01b3b6dfa6e8a8a68aeb8d97/sdk/packages/core/src/runtime/host/history.ts)
  filters root sessions and derives display conversation from string content or `text`
  blocks; and
- [`apps/cli/src/commands/program.ts`](https://github.com/cline/cline/blob/9e0015b78b97d89b01b3b6dfa6e8a8a68aeb8d97/apps/cli/src/commands/program.ts)
  exposes `--id <session-id>` for exact resume.

## What CodeReentry discovers

On explicit refresh, CodeReentry checks the configured `sessions.db` first. It validates
the required columns, rejects a symbolic-link or non-regular database, opens it with
`SQLITE_OPEN_READONLY`, and indexes at most 1,000 recent root sessions. A root session is
one where `is_subagent` is false and `parent_session_id` is empty, matching Cline's own
history filter. Discovery reads prompt and optional metadata title only; it does not open
message documents.

If the database does not exist, CodeReentry checks at most 1,000 direct session
directories for the official `<session-id>/<session-id>.json` manifest. Each manifest is
limited to 2 MiB, must be a regular file under the configured session root, and must have
the version-1 identity, timestamp, project-path, and message-path fields. It does not walk
arbitrary descendants or infer undocumented legacy locations.

The database modification token includes its WAL sidecar so an explicit refresh notices
live updates without opening the database for writing. `workspace_root` is preferred for
project binding, with absolute `cwd` as the documented fallback.

## Read, display, and resume bounds

Opening one conversation follows only its absolute `messages_path` after proving the
resolved regular file is exactly
`<session-root>/<session-id>/<session-id>.messages.json`. Symbolic links, cross-session
bindings, path escapes, missing files, malformed JSON, and files larger than 64 MiB
produce explicit errors. The reader keeps at most the newest 500 user/assistant messages and 2,000,000
rendered characters, with a 50,000-character cap per message. It accepts the two official
JSON shapes, includes string content and `type: "text"` blocks, and excludes system/tool
roles plus file, image, media, tool-use, tool-result, thinking, and redacted-thinking
blocks. Cline's generated `user_input` wrapper and `mode_notice` elements are removed only
for display; source data is never changed.

Continuing a record launches the user-configured executable in the bound project and
appends `--id <complete-session-id>`. CodeReentry does not abbreviate the ID, create a new
session, copy the transcript, or inject project memory into a resumed Cline conversation.

Tests use synthetic SQLite databases, manifests, and message documents derived from the
pinned schemas. They verify filtering, bounds, environment overrides, path containment,
symbolic-link rejection, and exact command construction. Cline is not installed on the
development Mac used for this change, so these tests are not evidence that a real recovery
attempt met the product-validation gate.
