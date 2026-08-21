# Pi compatibility boundary

CodeReentry's Pi integration is pinned to upstream tag **v0.84.2** at commit
[`914cf1472e715297caa30db4b9535d534a9eb718`](https://github.com/earendil-works/pi/tree/914cf1472e715297caa30db4b9535d534a9eb718).
The implementation is read-only and treats Pi's JSONL files as the source of truth.

## Verified upstream contract

- [`src/core/session-manager.ts`](https://github.com/earendil-works/pi/blob/914cf1472e715297caa30db4b9535d534a9eb718/packages/coding-agent/src/core/session-manager.ts)
  defines the version 3 header, `cwd`, append-only `id`/`parentId` tree, default
  `~/.pi/agent/sessions/--<encoded-cwd>--/` layout, and text/image/thinking/tool blocks.
- [`src/cli/args.ts`](https://github.com/earendil-works/pi/blob/914cf1472e715297caa30db4b9535d534a9eb718/packages/coding-agent/src/cli/args.ts)
  accepts `--session <path|id>` and `--session-dir <dir>`.
- [`src/main.ts`](https://github.com/earendil-works/pi/blob/914cf1472e715297caa30db4b9535d534a9eb718/packages/coding-agent/src/main.ts)
  resolves a session argument containing `/`, `\`, or `.jsonl` as a file path and opens
  that file directly. It gives `--session-dir` precedence over
  `PI_CODING_AGENT_SESSION_DIR` and settings.
- [Pi's package README](https://github.com/earendil-works/pi/blob/914cf1472e715297caa30db4b9535d534a9eb718/packages/coding-agent/README.md)
  documents the safe npm install command
  `npm install -g --ignore-scripts @earendil-works/pi-coding-agent`.

## Discovery and project binding

By default CodeReentry examines ordinary `.jsonl` files directly below
`~/.pi/agent/sessions/` and one project-directory level beneath it. When the current
process has an absolute `PI_CODING_AGENT_SESSION_DIR`, that directory is used instead.
Relative overrides are ignored because their meaning depends on the launching process's
cwd. `sessionDir` values from global or project settings and command-only
`--session-dir` overrides are not inferred in this version.

The root and candidate files must not be symbolic links. Enumeration, path length,
candidate count, and JSONL header size are bounded. Discovery reads only the first JSONL
header and filesystem metadata; it does not scan message bodies. The header's absolute
`cwd` is the sole project-binding source. The canonical absolute JSONL path is the local
session identity and the exact resume target.

## Conversation and resume boundary

Opening a selected session reads at most 64 MiB, 100,000 entries, 1 MiB per line, 500
visible messages, 50,000 characters per message, and 2,000,000 characters total. The
reader follows `parentId` from Pi's last entry to reconstruct the active branch. It shows
only `text` blocks from `user` and `assistant` messages. Images, thinking, tool calls,
tool results, compaction/branch summaries, custom extension entries, and hidden or
displayable custom messages are excluded. Malformed or broken data is surfaced as
truncated or rejected rather than silently treated as a complete transcript.

Resume starts the configured executable in the registered project directory with
`--session <canonical-absolute-jsonl-path>`. CodeReentry never edits, migrates, copies,
deletes, locks, or appends to the Pi file and does not inject project memory into a
resumed Pi conversation.

## Evidence status

The automated fixtures prove bounded discovery, active-branch selection, visible-text
filtering, override handling, unsafe-path rejection, and exact command construction. Pi
is not installed and no real Pi session exists on the development Mac, so these fixtures
are not a real recovery trial and no Pi outcome has been added to the evidence record.
