# Aider compatibility boundary

CodeReentry's Aider integration is pinned to the upstream **v0.86.2** tag at commit
[`253f0368b873ba30d8ee26e463718f0c03614ddf`](https://github.com/Aider-AI/aider/tree/253f0368b873ba30d8ee26e463718f0c03614ddf).
The implementation is read-only and treats Aider's file as the source of truth.

The verified upstream contracts are:

- [`aider/args.py`](https://github.com/Aider-AI/aider/blob/253f0368b873ba30d8ee26e463718f0c03614ddf/aider/args.py)
  selects `.aider.chat.history.md` under the Git root by default and exposes
  `--restore-chat-history`;
- [`aider/io.py`](https://github.com/Aider-AI/aider/blob/253f0368b873ba30d8ee26e463718f0c03614ddf/aider/io.py)
  records launch timestamps as `# aider chat started at ...`, user input under `#### `,
  assistant replies as ordinary Markdown, and tool/UI output as `> ` blockquotes;
- [`aider/utils.py`](https://github.com/Aider-AI/aider/blob/253f0368b873ba30d8ee26e463718f0c03614ddf/aider/utils.py)
  parses that Markdown and excludes tool rows from restored conversation context; and
- [`aider/coders/base_coder.py`](https://github.com/Aider-AI/aider/blob/253f0368b873ba30d8ee26e463718f0c03614ddf/aider/coders/base_coder.py)
  loads that parsed file when restore is requested.

## What CodeReentry discovers

On an explicit refresh, CodeReentry checks only the exact roots already registered as
projects. It considers the default `.aider.chat.history.md` only when it is a regular,
non-symbolic-link file directly under that root. It does not walk the home directory,
search parent directories, inspect `.aider.conf.yml`, or infer environment and CLI
overrides such as `AIDER_CHAT_HISTORY_FILE` or `--chat-history-file`.

Aider's default file is one append-only, continuing history for a project. It does not
provide a durable ID for each launch in this contract. CodeReentry therefore indexes at
most one Aider record per registered root; its local identity is the normalized form of
that registered project root. Continuing the record launches the configured Aider
executable in that project with `--restore-chat-history`. No synthetic ID is passed to
Aider.

## Read and display bounds

Discovery reads at most 4 MiB from the newest end of a history. The record uses the newest
visible Aider launch timestamp, falling back to the file modification time, because the
file represents continuing project work rather than one immutable session. Histories
larger than the discovery window report an unknown message count. Conversation loading
reads at most the newest 64 MiB, keeps at most 500 user/assistant messages and 2,000,000
rendered characters, caps each line at 1 MiB and each message at 50,000 characters, and
marks the result as truncated whenever a byte, line, message, or character bound applies.

The parser preserves Markdown blank lines, keeps the newest bounded context, skips Aider
launch headings, and excludes `> ` tool/status rows, matching the role boundary in
Aider's restore parser. Source files are never changed, locked, moved, copied, or opened
through a write-capable API.

Tests use synthetic histories derived from the pinned format. They demonstrate parser,
budget, symbolic-link, incremental-index, and command construction behavior; they are
not evidence that a real recovery attempt met the product-validation gate.
