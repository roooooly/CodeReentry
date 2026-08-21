# Reproducible Release performance baseline

DevHub measures performance with deterministic synthetic projects and session metadata,
never with a maintainer's real project paths, histories, prompts, or credentials. The
runner builds the verified Release app, creates a disposable macOS home profile, samples
the process with `ps` and `footprint`, writes only aggregate metrics under ignored
`local-data/`, then destroys the isolated profile.

## Reproduce it

The release-scale command includes a five-minute idle observation and ten refresh,
project-switch, detail-tab, global-navigation, and Settings/MCP/plugin cycles:

```bash
./scripts/performance-baseline.sh \
  --scale medium \
  --cycles 10 \
  --idle-seconds 300 \
  --recovery-seconds 10
```

Use `--scale small|medium|large`. The fixtures contain 5 projects / 100 sessions,
25 projects / 2,500 sessions, and 100 projects / 20,000 sessions respectively. The
measured app starts with the synthetic projects and source index but zero preindexed
sessions, matching a real first scan. After that scan, refresh and navigation operate
on the complete indexed set. Because production scans are only started by an explicit
button press, the runner brings the app to the foreground and declares user-initiated
activity after the idle observation and before scan timing. This prevents a synthetic
background timer from measuring App Nap throttling instead of the real re-entry path.
The runner also verifies that the post-scan store contains every expected session; a
fast partial import fails the scenario. Before measuring cycle-to-cycle growth it performs
one complete warm-up cycle so one-time AppKit/SwiftUI materialization is not mislabeled as
a leak; warm-up samples still count toward peak-memory budgets. A separate `full` fixture state verifies existing-index
loading; the benchmark no longer creates and deletes rows in the measured database.
That former approach left free pages behind and distorted first-scan timing. The global
session page initially materializes at most 500 recent metadata rows and loads
older batches only after an explicit click; conversation bodies are never part of this
scenario.

The script exits nonzero when any threshold in
[`scripts/performance-budget.json`](../scripts/performance-budget.json) fails. Raw sample
CSV and JSON files are local diagnostics, not release attachments.

## Baseline recorded 2026-08-21

Environment: arm64 Mac, macOS 26.5.2, ad-hoc-signed Release build. These numbers are a
regression reference for this checkout, not a promise that every Mac will match them.

| Scenario | Idle | Initial scan | Refresh P95 | Peak RSS | Peak physical | Recovery RSS | Cycle 1→10 | Result |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Small current, 5 / 100 | 300s | 58ms | 3ms | 159.0MiB | 93.6MiB | 155.0MiB | +4.9% | PASS |
| Medium current, 25 / 2,500 | 300s | 268ms | 12ms | 193.4MiB | 105.6MiB | 168.4MiB | -10.7% | PASS |
| Large current, 100 / 20,000 | 300s | 1,902ms | 25ms | 257.4MiB | 168.8MiB | 198.8MiB | -6.5% | PASS |
| Medium cold-first-cycle control, before warm-up | 300s | 264ms | 10ms | 200.4MiB | 109.7MiB | 200.0MiB | +23.0% | **FAIL: cycle growth only** |
| Large background-timer control, batched writer | 300s | 15,274ms | 77ms | 244.4MiB | 142.1MiB | 184.0MiB | -18.6% | **FAIL: scan budget only** |
| Large single-transaction writer | 300s | 16,540ms | 142ms | 335.0MiB | 237.5MiB | 205.1MiB | -37.5% | **FAIL: scan budget only** |
| Legacy fragmented-store method, before fixes | 300s | 44,368ms | 1,472ms | 776.0MiB | 753.8MiB | 308.4MiB | -58.7% | FAIL |

The current full large run's clean-launch peak RSS was 145.3MiB. At the end of five
minutes idle, RSS was 75.2MiB, physical footprint was 56.1MiB, and CPU was 0.0%. All
ten Settings windows opened, 120 navigation transitions completed, and the post-scan
row-count guard confirmed all 20,000 sessions. The initial scan took 1,902ms against
the unchanged 15,000ms budget: 1,530ms SQLite save, 292ms model mutation, 34ms
discovery/dedupe, and 15ms project matching. After a complete warm-up, cycle RSS
changed by -6.5% from the first measured cycle to the tenth.

The principal improvement came from normalizing project paths once, preparing stale
source cleanup and known-file timestamps in a single writer pass, caching only the
small source-file lookup for repeated refreshes, correcting the empty-index fixture,
bounding global-list materialization, and committing empty-store rebuilds in bounded
5,000-row batches. The latter is safe because SessionIndex is a rebuildable cache;
updates to an existing index remain a single transaction. The cache checks source
existence on every refresh and invalidates itself when a source disappears.

## Regression budgets

Budgets are deliberately looser than the medium baseline and act as tripwires, not
optimization targets.

| Scale | Initial scan | Refresh P95 | Peak RSS | Peak physical | Recovery RSS | Cycle growth |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Small | 2,000ms | 1,000ms | 300MiB | 250MiB | 250MiB | ≤20% |
| Medium | 5,000ms | 1,500ms | 400MiB | 350MiB | 325MiB | ≤20% |
| Large | 15,000ms | 3,000ms | 650MiB | 600MiB | 500MiB | ≤20% |

## 中文摘要

性能脚本只使用确定性的合成项目与会话元数据，并在一次性 macOS 用户目录中运行，不会
读取真实项目、历史会话、提示词或凭据。场景现在从真正的空会话索引开始，不再先写入再
删除数据制造碎片。warm-up 本身仍参与峰值内存预算，只是不再把界面首次加载误判为
循环泄漏。小型和中型正式基线均已通过：100 条初扫 58 毫秒，2,500 条初扫 268 毫秒、
刷新 P95 12 毫秒。
大型场景在完整 5 分钟空闲、用户重新激活应用、10 轮交互和 20,000 行完整性校验下，
正式初扫为 1.902 秒，刷新 P95 为 25 毫秒，峰值物理占用为 168.8MiB，全部预算通过。
预算仍保持 15 秒，没有为制造通过结果而降低；文档也保留了 15.274 秒后台定时器对照和
16.540 秒单事务写入结果，便于审计触发条件与优化收益。
