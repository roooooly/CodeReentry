# Roadmap

DevHub is currently a source beta. This roadmap describes product gates and bounded
work areas, not promised dates.

## Public beta gates

- [ ] Choose a distinctive public product name before broad promotion.
- [ ] Produce a Developer ID signed and Apple-notarized macOS build.
- [ ] Publish a verifiable DMG, release notes, checksum, and update policy.
- [ ] Complete the [privacy-safe repeated real-use checks](docs/reentry-validation.md)
      of the project-to-session recovery flow.
- [ ] Document tested third-party tool versions and known format limits.
- [x] Clear every [Release performance budget](docs/performance-baseline.md); the current
      small, medium, and 20,000-session large scenarios all pass without weakening budgets.

## Core recovery flow

- Improve the path from project selection to the latest useful session.
- Keep session indexing incremental, bounded, cancellable, and user initiated.
- Make every memory handoff reviewable before it reaches another tool.
- Add compatibility only with synthetic fixtures and explicit failure states.
- Keep missing paths, unreadable records, and unsupported resume behavior honest.

## Contributor-sized work

Good contributions should be independently testable and avoid broad product expansion.
Examples include:

- a sanitized fixture for a documented session-format edge case;
- a compatibility note verified against a named tool version;
- an accessibility fix with a focused regression test;
- a translation correction that preserves the English/Chinese route boundary;
- a performance improvement with before/after measurements on synthetic data.

See the repository Issues for work that is currently accepted.

## Non-goals

- Uploading source projects or session histories to a DevHub cloud service
- Silent background crawling of complete conversation histories
- Claiming lossless full-session migration between unrelated tools
- Adding integrations without a concrete project-recovery use case
- Collecting behavioral telemetry to optimize engagement

The roadmap changes when real use reveals a better priority. Engineering completion is
reported separately from evidence that a workflow helps users.
