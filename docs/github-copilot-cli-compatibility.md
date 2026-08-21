# GitHub Copilot CLI compatibility evidence

CodeReentry's GitHub Copilot CLI reader is based on GitHub's public documentation at
[`github/docs@c34e3dccad00f61133c799d20e7d1208a0e6cc92`](https://github.com/github/docs/tree/c34e3dccad00f61133c799d20e7d1208a0e6cc92/content/copilot)
and the public Copilot CLI repository at
[`github/copilot-cli@3f9c5e1ce792150a852804132e2b08c58e9a8e95`](https://github.com/github/copilot-cli/commit/3f9c5e1ce792150a852804132e2b08c58e9a8e95),
inspected on 2026-08-21. The CLI repository identified v1.0.80 as the current release at
that snapshot. This note records the compatibility boundary so upstream changes can be
reviewed instead of guessed.

## Verified contract

- [Configuration directory reference](https://github.com/github/docs/blob/c34e3dccad00f61133c799d20e7d1208a0e6cc92/content/copilot/reference/copilot-cli-reference/cli-config-dir-reference.md)
  documents `~/.copilot/session-state/`, one subdirectory per session ID, and an
  `events.jsonl` event log used by resume.
- [Streaming events](https://github.com/github/docs/blob/c34e3dccad00f61133c799d20e7d1208a0e6cc92/content/copilot/how-tos/copilot-sdk/features/streaming-events.md)
  defines the persisted event envelope and the fields CodeReentry reads:
  `timestamp`, `agentId`, `type`, `data`, `user.message`, `assistant.message`, and
  `session.context_changed`. Envelope-level `agentId` identifies subagent events.
- [CLI command reference](https://github.com/github/docs/blob/c34e3dccad00f61133c799d20e7d1208a0e6cc92/content/copilot/reference/copilot-cli-reference/cli-command-reference.md)
  documents `copilot --resume <session-id>`, `copilot` for a new interactive session,
  and the `--resume` conflict and non-TTY behavior.
- [Session persistence](https://github.com/github/docs/blob/c34e3dccad00f61133c799d20e7d1208a0e6cc92/content/copilot/how-tos/copilot-sdk/features/session-persistence.md)
  states that complete conversation history is persisted locally and warns that
  concurrent access to one session is undefined.
- [The official CLI README](https://github.com/github/copilot-cli/blob/3f9c5e1ce792150a852804132e2b08c58e9a8e95/README.md)
  documents the `copilot` executable and `brew install copilot-cli` installation path.

## CodeReentry boundary

The implementation is read-only. It never writes to Copilot's session directory and
never opens a session during discovery. It accepts a project path only from a documented
`session.context_changed` event and requires an absolute path; `gitRoot` is preferred to
`cwd` when both are present.

CodeReentry displays root-agent user and assistant messages plus bounded tool-request
arguments. It intentionally excludes system/developer prompts, assistant reasoning,
ephemeral streaming deltas, and every event carrying `agentId`. This is a privacy and
product boundary, not a claim that those events are absent from the source log.

The reader enforces these hard caps:

- 1,000 recent session directories per refresh;
- 2 MiB of metadata scanning for a large event log;
- 64 MiB for an explicitly opened conversation;
- 1 MiB per JSONL line, 500 displayed messages, 50,000 characters per message, and
  2,000,000 displayed characters per conversation;
- no following of symbolic-linked session directories or event logs.

A history that reaches a byte, line, message, or character bound is marked as truncated.
Tests use synthetic records derived from the documented event schema. The development
machine used for this compatibility change had no Copilot CLI session history, so this
evidence does not claim a privacy-safe real-user trial or replace the separate re-entry
validation gate.

## Maintenance rule

Before changing GitHub Copilot CLI compatibility, compare the current configuration
directory, event schema, context event, resume flag, executable, and installation path
against these snapshots. Update the pinned sources, sanitized fixtures, limits, tests,
README table, and changelog in the same pull request.
