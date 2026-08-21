# Privacy-safe project re-entry validation

CodeReentry's core hypothesis is not proven by test counts: a real developer should reach
the correct project, session, and usable context faster, without leaking context across
projects. This protocol turns that claim into a falsifiable local trial while keeping
project names, paths, prompts, session text, and source content out of the repository.

## Record a real attempt in the app

The normal path is built into CodeReentry:

1. Open a registered project's **Sessions** tab and inspect the intended conversation.
2. Select **Measure This Recovery** in the conversation header. CodeReentry starts a
   local timer, opens the exact session in the original tool, and leaves the evidence
   page ready for your return.
3. Confirm the project, session, and context in the original tool, return to CodeReentry,
   and submit the baseline, correctness, coarse repeated-background reduction, and any
   failure category.

Selecting **Record Recovery Result** freezes the timer before the form opens, so time spent
entering the structured result is not counted as recovery time. Canceling the form keeps
that frozen duration available for an honest later submission; discarding the measurement
records nothing.

The app writes the same strict 12-column schema used by the CLI to the owner-only file
`~/Library/Application Support/CodeReentry/reentry-trials.csv`. It deterministically
derives an anonymous project slot before recording. It never writes the source
project identifier, project name, path, session ID, prompt, conversation body, or notes.
There is no upload or telemetry path. An unfinished timer exists only in memory and is
discarded when the app exits.

The evidence page also provides an explicit, destructive **Delete All Local Records**
action. After confirmation it removes the evidence CSV and unfinished timer, while leaving
projects, sessions, source files, and unrelated application-support data untouched.

The **Recovery Evidence** page summarizes local attempts and shows coverage and outcome
gates without presenting development fixtures as real evidence.

## Record a real attempt with the CLI

First complete the same task without CodeReentry, or use a recent comparable attempt as the
baseline. Start the timer when you decide to resume work and stop it when the coding
tool has the correct project, intended session, and enough context for the first valid
task. Then record only anonymous categories:

```bash
./scripts/reentry-trial.sh record \
  --project-slot p1 \
  --tool codex \
  --session-age recent \
  --baseline-seconds 120 \
  --devhub-seconds 45 \
  --outcome correct \
  --reduction-band 70-99 \
  --cross-project no \
  --failure none
```

Use the same anonymous slot (`p1`, `p2`, and so on) for the same project. Never put a
real project name in the slot. The recorder deliberately rejects free-form project
identifiers and has no fields for paths, prompts, notes, or conversation content.

CLI results are written with owner-only permissions to the ignored local file
`local-data/reentry-trials.csv`. This is deliberately separate from the installed app's
Application Support file. Do not move either raw file into a tracked directory or commit it.

Allowed values and failure categories are available through:

```bash
./scripts/reentry-trial.sh --help
```

## Run the evidence gate

After at least ten attempts over seven days, covering at least three anonymous project
slots, two tools, and both recent and older sessions, run:

```bash
./scripts/reentry-trial.sh summary
```

The initial targets from [GitHub issue #7](https://github.com/roooooly/CodeReentry/issues/7) are:

- at least 9/10 attempts reach the correct project, session, and usable context;
- median CodeReentry time is at most 60 seconds and at least 50% faster than the baseline;
- approximate median repeated-background reduction is at least 70%;
- cross-project context incidents remain at zero.

The reduction value is intentionally a coarse band, converted to a midpoint only for
the summary. It is not token telemetry. A failed gate is useful evidence: keep the
failure category, change the product, and repeat rather than weakening the target.

## 中文说明

工程测试数量不能证明 CodeReentry 真能帮助用户。真实复访应从“决定继续旧项目”开始计时，
到开发工具进入正确项目、正确会话，并具备执行第一项有效任务所需的上下文时停止。

优先在项目“会话”页打开目标会话，点击“测量这次恢复”。CodeReentry 会在本机开始计时、
打开原工具，并把界面切到“恢复证据”；确认项目、会话和上下文后回来填写结果。应用只把
匿名项目槽位、工具、会话新旧、耗时、结果枚举和失败分类写入权限为 `0600` 的
`~/Library/Application Support/CodeReentry/reentry-trials.csv`。匿名槽位在写入前由稳定项目
标识单向派生，原标识、项目名、路径、会话 ID、提示词、备注和正文均不进入记录，也不会上传。

仓库中的 `./scripts/reentry-trial.sh` 仍可用于手动记录，文件位于被 Git 忽略的
`local-data/reentry-trials.csv`，两种入口使用同一严格格式但不自动合并。至少用三项项目、
两种工具完成十次真实复访，同时覆盖近期和较早会话及七天跨度。若正确率、耗时、重复背景
减少或跨项目上下文指标未达到目标，应保留失败证据并继续改产品，而不是降低标准。

点击“记录恢复结果”时计时会先冻结，因此填写表单的时间不会污染恢复耗时。证据页也提供
“删除全部本地记录”操作；再次确认后只删除证据 CSV 与未完成计时，不删除项目、会话、源码
或其他应用数据。
