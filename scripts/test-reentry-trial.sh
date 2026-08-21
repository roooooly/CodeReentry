#!/bin/sh
set -eu

devhub_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
devhub_test_root=$(mktemp -d "${TMPDIR:-/tmp}/devhub-reentry-test.XXXXXX")
trap 'rm -rf "$devhub_test_root"' EXIT HUP INT TERM
devhub_test_file="$devhub_test_root/reentry-trials.csv"
devhub_recorder="$devhub_repo_root/scripts/reentry-trial.sh"

devhub_attempt=1
while test "$devhub_attempt" -le 10; do
  case $((devhub_attempt % 3)) in
    1) devhub_project=p1 ;;
    2) devhub_project=p2 ;;
    0) devhub_project=p3 ;;
  esac
  if test $((devhub_attempt % 2)) -eq 0; then
    devhub_tool=codex
    devhub_age=recent
  else
    devhub_tool=claude-code
    devhub_age=older
  fi
  devhub_outcome=correct
  devhub_failure=none
  if test "$devhub_attempt" -eq 10; then
    devhub_outcome=wrong-session
    devhub_failure=session-not-found
  fi
  devhub_recorded_epoch=$((1700000000 + (devhub_attempt - 1) * 57600))
  DEVHUB_REENTRY_DATA_FILE="$devhub_test_file" \
  DEVHUB_REENTRY_NOW_EPOCH="$devhub_recorded_epoch" "$devhub_recorder" record \
    --project-slot "$devhub_project" --tool "$devhub_tool" --session-age "$devhub_age" \
    --baseline-seconds 120 --devhub-seconds 45 --outcome "$devhub_outcome" \
    --reduction-band 70-99 --cross-project no --failure "$devhub_failure" >/dev/null
  devhub_attempt=$((devhub_attempt + 1))
done

devhub_lines=$(wc -l < "$devhub_test_file" | tr -d ' ')
test "$devhub_lines" -eq 11
devhub_permissions=$(stat -c '%a' "$devhub_test_file" 2>/dev/null || stat -f '%Lp' "$devhub_test_file")
test "$devhub_permissions" = 600

devhub_summary=$(DEVHUB_REENTRY_DATA_FILE="$devhub_test_file" "$devhub_recorder" summary)
case "$devhub_summary" in *'Attempts: 10 (coverage gate: COVERAGE MET)'*) ;; *) exit 1 ;; esac
case "$devhub_summary" in *'Recorded span: 7 days'*) ;; *) exit 1 ;; esac
case "$devhub_summary" in *'Correct project/session/context: 9/10 (90%)'*) ;; *) exit 1 ;; esac
case "$devhub_summary" in *'Median time: 45s with CodeReentry vs 120s baseline; relative improvement: 62%'*) ;; *) exit 1 ;; esac
case "$devhub_summary" in *'Approximate median repeated-background reduction: 85%'*) ;; *) exit 1 ;; esac
case "$devhub_summary" in *'Cross-project context incidents: 0'*) ;; *) exit 1 ;; esac
case "$devhub_summary" in *'Initial outcome targets: TARGETS MET'*) ;; *) exit 1 ;; esac
case "$devhub_summary" in *'- session-not-found: 1'*) ;; *) exit 1 ;; esac

devhub_before=$(wc -l < "$devhub_test_file" | tr -d ' ')
if DEVHUB_REENTRY_DATA_FILE="$devhub_test_file" "$devhub_recorder" record \
  --project-slot 'p12SecretProjectName' --tool codex --session-age recent \
  --baseline-seconds 120 --devhub-seconds 45 --outcome correct \
  --reduction-band 70-99 --cross-project no --failure none >/dev/null 2>&1; then
  exit 1
fi
devhub_after=$(wc -l < "$devhub_test_file" | tr -d ' ')
test "$devhub_before" -eq "$devhub_after"

if DEVHUB_REENTRY_DATA_FILE="$devhub_test_file" "$devhub_recorder" record \
  --project-slot p1 --tool codex --session-age recent \
  --baseline-seconds 120 --devhub-seconds 45 --outcome correct \
  --reduction-band 70-99 --cross-project no --failure stale-summary >/dev/null 2>&1; then
  exit 1
fi

devhub_short_file="$devhub_test_root/short-span.csv"
devhub_attempt=1
while test "$devhub_attempt" -le 10; do
  if test $((devhub_attempt % 2)) -eq 0; then
    devhub_short_tool=codex
    devhub_short_age=recent
  else
    devhub_short_tool=claude-code
    devhub_short_age=older
  fi
  DEVHUB_REENTRY_DATA_FILE="$devhub_short_file" DEVHUB_REENTRY_NOW_EPOCH=1700000000 \
    "$devhub_recorder" record \
      --project-slot "p$(((devhub_attempt - 1) % 3 + 1))" \
      --tool "$devhub_short_tool" --session-age "$devhub_short_age" \
      --baseline-seconds 120 --devhub-seconds 45 --outcome correct \
      --reduction-band 70-99 --cross-project no --failure none >/dev/null
  devhub_attempt=$((devhub_attempt + 1))
done
devhub_short_summary=$(DEVHUB_REENTRY_DATA_FILE="$devhub_short_file" "$devhub_recorder" summary)
case "$devhub_short_summary" in *'Attempts: 10 (coverage gate: PENDING)'*) ;; *) exit 1 ;; esac
case "$devhub_short_summary" in *'Recorded span: 1 day'*) ;; *) exit 1 ;; esac
case "$devhub_short_summary" in *'Initial outcome targets: NOT MET'*) ;; *) exit 1 ;; esac

devhub_tampered_file="$devhub_test_root/tampered.csv"
cp "$devhub_test_file" "$devhub_tampered_file"
printf '%s\n' '11,not-a-date,0,p1,codex,recent,1,1,correct,100,no,none' >> "$devhub_tampered_file"
if DEVHUB_REENTRY_DATA_FILE="$devhub_tampered_file" "$devhub_recorder" summary >/dev/null 2>&1; then
  exit 1
fi

devhub_header=$(sed -n '1p' "$devhub_test_file")
case "$devhub_header" in *path*|*prompt*|*content*|*notes*) exit 1 ;; esac

devhub_new_tools_file="$devhub_test_root/new-tools.csv"
DEVHUB_REENTRY_DATA_FILE="$devhub_new_tools_file" DEVHUB_REENTRY_NOW_EPOCH=1700000000 \
  "$devhub_recorder" record \
    --project-slot p1 --tool gemini-cli --session-age recent \
    --baseline-seconds 120 --devhub-seconds 45 --outcome correct \
    --reduction-band 70-99 --cross-project no --failure none >/dev/null
DEVHUB_REENTRY_DATA_FILE="$devhub_new_tools_file" DEVHUB_REENTRY_NOW_EPOCH=1700000001 \
  "$devhub_recorder" record \
    --project-slot p2 --tool github-copilot --session-age older \
    --baseline-seconds 120 --devhub-seconds 45 --outcome correct \
    --reduction-band 70-99 --cross-project no --failure none >/dev/null
DEVHUB_REENTRY_DATA_FILE="$devhub_new_tools_file" DEVHUB_REENTRY_NOW_EPOCH=1700000002 \
  "$devhub_recorder" record \
    --project-slot p3 --tool aider --session-age recent \
    --baseline-seconds 120 --devhub-seconds 45 --outcome correct \
    --reduction-band 70-99 --cross-project no --failure none >/dev/null
DEVHUB_REENTRY_DATA_FILE="$devhub_new_tools_file" DEVHUB_REENTRY_NOW_EPOCH=1700000003 \
  "$devhub_recorder" record \
    --project-slot p4 --tool cline --session-age older \
    --baseline-seconds 120 --devhub-seconds 45 --outcome correct \
    --reduction-band 70-99 --cross-project no --failure none >/dev/null
DEVHUB_REENTRY_DATA_FILE="$devhub_new_tools_file" DEVHUB_REENTRY_NOW_EPOCH=1700000004 \
  "$devhub_recorder" record \
    --project-slot p5 --tool goose --session-age recent \
    --baseline-seconds 120 --devhub-seconds 45 --outcome correct \
    --reduction-band 70-99 --cross-project no --failure none >/dev/null
DEVHUB_REENTRY_DATA_FILE="$devhub_new_tools_file" DEVHUB_REENTRY_NOW_EPOCH=1700000005 \
  "$devhub_recorder" record \
    --project-slot p6 --tool pi --session-age older \
    --baseline-seconds 120 --devhub-seconds 45 --outcome correct \
    --reduction-band 70-99 --cross-project no --failure none >/dev/null
test "$(wc -l < "$devhub_new_tools_file" | tr -d ' ')" -eq 7
grep -q ',gemini-cli,' "$devhub_new_tools_file"
grep -q ',github-copilot,' "$devhub_new_tools_file"
grep -q ',aider,' "$devhub_new_tools_file"
grep -q ',cline,' "$devhub_new_tools_file"
grep -q ',goose,' "$devhub_new_tools_file"
grep -q ',pi,' "$devhub_new_tools_file"

printf '%s\n' 'reentry-trial tests: passed'
