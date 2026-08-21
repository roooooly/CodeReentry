# Privacy-safe project re-entry validation

CodeReentry's core hypothesis is not proven by test counts: a real developer should reach
the correct project, session, and usable context faster, without leaking context across
projects. This protocol turns that claim into a falsifiable local trial while keeping
project names, paths, prompts, session text, and source content out of the repository.

## Record a real attempt

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

Results are written with owner-only permissions to the ignored local file
`local-data/reentry-trials.csv`. Do not move the raw file into a tracked directory.

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

记录时只使用 `p1`、`p2` 这类匿名项目槽位、工具名、耗时、结果枚举和失败分类。脚本不
提供项目名、路径、提示词、备注或会话正文输入字段，记录文件也只保存在被 Git 忽略的
`local-data/reentry-trials.csv`。至少用三项项目、两种工具完成十次真实复访，同时覆盖近期
和较早会话，再运行 `./scripts/reentry-trial.sh summary`。如果正确率、耗时、重复背景减少
或跨项目上下文指标未达到目标，应保留失败证据并继续改产品，而不是降低标准。
