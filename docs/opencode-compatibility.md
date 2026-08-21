# OpenCode compatibility boundary

CodeReentry's OpenCode integration is verified against OpenCode v1.18.19 at upstream
commit [`2b72179c663cadcb54f54d9f19221b3fb3d11fb6`](https://github.com/anomalyco/opencode/tree/2b72179c663cadcb54f54d9f19221b3fb3d11fb6).
The integration treats OpenCode's database as a read-only, tool-owned source of truth.

## Pinned upstream evidence

The implementation follows these files from that exact upstream commit:

- [`packages/core/src/session/sql.ts`](https://github.com/anomalyco/opencode/blob/2b72179c663cadcb54f54d9f19221b3fb3d11fb6/packages/core/src/session/sql.ts)
  defines the `session`, `message`, and `part` tables and their foreign-key relationships.
- [`packages/schema/src/v1/session.ts`](https://github.com/anomalyco/opencode/blob/2b72179c663cadcb54f54d9f19221b3fb3d11fb6/packages/schema/src/v1/session.ts)
  defines user and assistant message roles plus text, reasoning, tool, attachment, and
  execution-bookkeeping part types.
- [`packages/opencode/src/session/message-v2.ts`](https://github.com/anomalyco/opencode/blob/2b72179c663cadcb54f54d9f19221b3fb3d11fb6/packages/opencode/src/session/message-v2.ts)
  shows that message rows are loaded by session and hydrated with ordered part rows.

These upstream files are primary compatibility evidence. The CodeReentry test database is
fully synthetic and contains no copied user conversation data.

## What CodeReentry reads

An explicit refresh opens at most eight configured/default/channel databases with
`SQLITE_OPEN_READONLY`, validates the `session` table, and indexes at most 1,000 recent
unarchived session metadata rows per database. Discovery does not query `message.data` or
`part.data`.

When the user opens one OpenCode conversation, CodeReentry locates that session, validates
the required `message` and `part` columns, and reads only rows belonging to the requested
session. The detail view includes:

- user and assistant `text` parts;
- tool names and structured tool inputs from `tool` parts.

It deliberately excludes `reasoning` parts, attachments, snapshots, patches, retries,
compaction markers, and other execution bookkeeping. The source database remains unchanged.

## Resource and failure bounds

Conversation loading is bounded to the newest 500 messages, 2,000 parts, 2 MiB per JSON
cell, 50,000 characters per rendered part, and 2,000,000 rendered characters in total.
Callers may request smaller limits for tests, but cannot raise these hard ceilings. If a
limit or malformed JSON causes content to be omitted, the returned conversation is marked
as truncated so the UI does not imply completeness.

Missing required columns, a database that cannot be opened read-only, query failures, and
unknown session IDs all produce explicit errors. A future OpenCode storage change must be
verified against a named upstream version and synthetic fixtures before this boundary is
expanded.
