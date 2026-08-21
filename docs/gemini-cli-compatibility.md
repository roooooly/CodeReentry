# Gemini CLI compatibility evidence

CodeReentry's Gemini CLI reader is based on the public upstream source at commit
[`30573d2e4d85bdc2c0ae8218c377cd410336da77`](https://github.com/google-gemini/gemini-cli/commit/30573d2e4d85bdc2c0ae8218c377cd410336da77),
inspected on 2026-08-21. This note records the contract so future upstream changes can be
reviewed instead of silently guessed.

## Verified contract

- [Session management](https://github.com/google-gemini/gemini-cli/blob/30573d2e4d85bdc2c0ae8218c377cd410336da77/docs/cli/session-management.md)
  stores project-scoped histories below `~/.gemini/tmp/<project-id>/chats/` and resumes
  an exact session with `gemini --resume <full-uuid>`.
- [Conversation record types](https://github.com/google-gemini/gemini-cli/blob/30573d2e4d85bdc2c0ae8218c377cd410336da77/packages/core/src/services/chatRecordingTypes.ts)
  define JSONL metadata, user and Gemini messages, tool calls, rewind records, metadata
  checkpoints, and main versus subagent sessions.
- [The project registry](https://github.com/google-gemini/gemini-cli/blob/30573d2e4d85bdc2c0ae8218c377cd410336da77/packages/core/src/config/projectRegistry.ts)
  maps absolute project paths to opaque directory identifiers. A project's
  `.project_root` ownership marker is authoritative when present.
- [The official installation guide](https://github.com/google-gemini/gemini-cli/blob/30573d2e4d85bdc2c0ae8218c377cd410336da77/docs/get-started/installation.mdx)
  documents the `@google/gemini-cli` npm package used by CodeReentry's install action.

## CodeReentry boundary

The implementation is read-only. It does not infer project paths from opaque directory
names or hashes, does not modify Gemini CLI files, and does not surface subagent files as
independent resumable sessions.

The reader enforces these hard caps:

- 100 project directories and 1,000 recent session files per refresh;
- 2 MiB of metadata scanning for a large session file;
- 64 MiB for an explicitly opened conversation;
- 1 MiB per JSONL line, 500 displayed messages, 50,000 characters per message, and
  2,000,000 displayed characters per conversation;
- 64 KiB for an ownership marker or project registry.

A history that reaches a byte, line, message, or character bound is marked as truncated.
The tests use synthetic records derived from the public schema; no developer or user
session content is committed to this repository.

## Maintenance rule

Before changing Gemini CLI compatibility, compare the current upstream session schema,
loader, project registry, resume flag, and install package against this snapshot. Update
the pinned source links, sanitized fixtures, limits, tests, README table, and changelog in
the same pull request.
