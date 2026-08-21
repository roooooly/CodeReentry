# Goose compatibility boundary

CodeReentry's Goose integration is pinned to upstream tag **v1.46.0** at commit
[`98c11ce2ee7b9b302978aa64b1eab7d0895607c7`](https://github.com/aaif-goose/goose/tree/98c11ce2ee7b9b302978aa64b1eab7d0895607c7).
The implementation is read-only and treats Goose's SQLite database as the source of truth.

## Pinned upstream evidence

The compatibility contract comes from these files at that exact commit:

- [`crates/goose/src/config/paths.rs`](https://github.com/aaif-goose/goose/blob/98c11ce2ee7b9b302978aa64b1eab7d0895607c7/crates/goose/src/config/paths.rs)
  defines the macOS data directory and accepts `GOOSE_PATH_ROOT` only when it is an
  absolute path;
- [`crates/goose/src/session/session_manager.rs`](https://github.com/aaif-goose/goose/blob/98c11ce2ee7b9b302978aa64b1eab7d0895607c7/crates/goose/src/session/session_manager.rs)
  defines schema version 16, `sessions.db`, the `sessions` and `messages` tables,
  user-session types, visibility metadata, timestamp ordering, and readback behavior;
- [`crates/goose-provider-types/src/conversation/message.rs`](https://github.com/aaif-goose/goose/blob/98c11ce2ee7b9b302978aa64b1eab7d0895607c7/crates/goose-provider-types/src/conversation/message.rs)
  defines text, image, tool, thinking, notification, and error content variants plus the
  `userVisible` metadata flag; and
- [`crates/goose-cli/src/cli.rs`](https://github.com/aaif-goose/goose/blob/98c11ce2ee7b9b302978aa64b1eab7d0895607c7/crates/goose-cli/src/cli.rs)
  and [`crates/goose-cli/src/session/builder.rs`](https://github.com/aaif-goose/goose/blob/98c11ce2ee7b9b302978aa64b1eab7d0895607c7/crates/goose-cli/src/session/builder.rs)
  prove that `goose session --resume --session-id <complete-id>` validates and resumes
  that exact stored session.

Goose's [official environment-variable guide](https://github.com/aaif-goose/goose/blob/98c11ce2ee7b9b302978aa64b1eab7d0895607c7/documentation/docs/guides/environment-variables.md)
documents `~/Library/Application Support/Block/goose/` as the macOS default root. The
database is therefore `sessions/sessions.db` below that directory. With an absolute
`GOOSE_PATH_ROOT`, it is `data/sessions/sessions.db`, matching the source implementation.

## Discovery and project binding

Discovery happens only on the user's explicit refresh. CodeReentry validates the named
columns, opens the database with `SQLITE_OPEN_READONLY`, and indexes at most the newest
1,000 rows whose official `session_type` is `user`. Scheduled, subagent, hidden, terminal,
gateway, and ACP sessions are not presented as resumable user conversations. The database
and WAL modification times form the incremental refresh token.

Discovery reads only the ID, working directory, name/description, and timestamps. It does
not query `content_json`; the title becomes the preview rather than extracting prompt text.
The exact persisted `working_dir` binds the session to a registered project.

## Conversation and resume bounds

Opening one session validates the `messages` schema and selects only rows for that exact
user-session ID. It respects Goose's `metadata_json.userVisible` flag and keeps only
`type: "text"` blocks from user and assistant rows. Images, tool requests, tool responses,
tool confirmations, frontend actions, thinking, redacted thinking, notifications, and
errors remain in Goose and are not displayed by CodeReentry.

The reader keeps at most the newest 500 message rows, 2 MiB per JSON cell, 50,000 rendered
characters per message, and 2,000,000 rendered characters in total. Oversized or malformed
content is omitted and marks the detail as truncated. Callers may lower but cannot raise
these limits. Source rows are never updated, copied, locked, deleted, or migrated.

Continue launches the user-configured executable in the bound project and appends
`session --resume --session-id <complete-session-id>`. CodeReentry does not abbreviate the
ID, select the latest session implicitly, create a fork, or inject project memory into the
resumed conversation.

Tests use synthetic SQLite records derived from the pinned schema. Goose is not installed
and no real Goose session exists on the development Mac used for this change, so the tests
do not count as a real recovery trial or prove that the product-validation gate has passed.
