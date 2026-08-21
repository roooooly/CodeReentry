#!/bin/sh
set -eu

devhub_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
devhub_data_file=${DEVHUB_REENTRY_DATA_FILE:-"$devhub_repo_root/local-data/reentry-trials.csv"}
devhub_header='attempt_id,recorded_at,recorded_epoch,project_slot,tool,session_age,baseline_seconds,devhub_seconds,outcome,repeated_background_reduction_band,cross_project_context,failure_category'

usage() {
  printf '%s\n' \
    'Usage:' \
    '  ./scripts/reentry-trial.sh record \' \
    '    --project-slot p1 --tool codex --session-age recent \' \
    '    --baseline-seconds 120 --devhub-seconds 45 --outcome correct \' \
    '    --reduction-band 70-99 --cross-project no --failure none' \
    '  ./scripts/reentry-trial.sh summary' \
    '' \
    'Accepted values:' \
    '  project slot: p1, p2, ... (anonymous; never use a project name)' \
    '  tool: claude-code | codex | zcode | opencode | kimi | gemini-cli | github-copilot | aider | cline' \
    '  session age: recent | older' \
    '  outcome: correct | wrong-project | wrong-session | unusable-context | launch-failed' \
    '  reduction band: 0 | 1-29 | 30-69 | 70-99 | 100' \
    '  cross-project: no | yes' \
    '  failure: none | path-missing | session-not-found | reader-unsupported |' \
    '           resume-unsupported | wrong-binding | stale-summary | tool-launch | other' \
    '' \
    'The recorder intentionally has no fields for names, paths, prompts, notes, or content.'
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 64
}

require_value() {
  test -n "$2" || fail "missing $1"
}

validate_enum() {
  devhub_label=$1
  devhub_value=$2
  shift 2
  for devhub_allowed in "$@"; do
    test "$devhub_value" = "$devhub_allowed" && return 0
  done
  fail "invalid $devhub_label: $devhub_value"
}

validate_positive_integer() {
  devhub_label=$1
  devhub_value=$2
  case "$devhub_value" in
    ''|*[!0-9]*|0) fail "$devhub_label must be a positive integer" ;;
  esac
}

ensure_data_file() {
  if test -L "$devhub_data_file"; then
    fail 'refusing to write through a symbolic link'
  fi
  devhub_data_dir=$(dirname -- "$devhub_data_file")
  umask 077
  mkdir -p "$devhub_data_dir"
  if test ! -f "$devhub_data_file"; then
    printf '%s\n' "$devhub_header" > "$devhub_data_file"
  fi
  devhub_existing_header=$(sed -n '1p' "$devhub_data_file")
  test "$devhub_existing_header" = "$devhub_header" || fail 'unexpected trial file schema'
  if ! awk -F, '
    NR == 1 { next }
    {
      expected += 1
      valid = (NF == 12)
      valid = valid && ($1 == expected)
      valid = valid && ($2 != "")
      valid = valid && ($3 ~ /^[0-9]+$/ && $3 > 0)
      valid = valid && ($4 ~ /^p[1-9][0-9]*$/)
      valid = valid && ($5 ~ /^(claude-code|codex|zcode|opencode|kimi|gemini-cli|github-copilot|aider|cline)$/)
      valid = valid && ($6 ~ /^(recent|older)$/)
      valid = valid && ($7 ~ /^[0-9]+$/ && $7 > 0)
      valid = valid && ($8 ~ /^[0-9]+$/ && $8 > 0)
      valid = valid && ($9 ~ /^(correct|wrong-project|wrong-session|unusable-context|launch-failed)$/)
      valid = valid && ($10 ~ /^(0|1-29|30-69|70-99|100)$/)
      valid = valid && ($11 ~ /^(no|yes)$/)
      valid = valid && ($12 ~ /^(none|path-missing|session-not-found|reader-unsupported|resume-unsupported|wrong-binding|stale-summary|tool-launch|other)$/)
      valid = valid && !(($9 == "correct") != ($12 == "none"))
      valid = valid && !($9 == "correct" && $11 == "yes")
      if (!valid) exit 1
    }
  ' "$devhub_data_file"; then
    fail 'trial file contains an invalid or manually altered row'
  fi
}

record_trial() {
  devhub_project_slot=''
  devhub_tool=''
  devhub_session_age=''
  devhub_baseline_seconds=''
  devhub_elapsed_seconds=''
  devhub_outcome=''
  devhub_reduction_band=''
  devhub_cross_project=''
  devhub_failure=''

  while test "$#" -gt 0; do
    devhub_option=$1
    shift
    case "$devhub_option" in
      --project-slot) require_value "$devhub_option" "${1:-}"; devhub_project_slot=$1; shift ;;
      --tool) require_value "$devhub_option" "${1:-}"; devhub_tool=$1; shift ;;
      --session-age) require_value "$devhub_option" "${1:-}"; devhub_session_age=$1; shift ;;
      --baseline-seconds) require_value "$devhub_option" "${1:-}"; devhub_baseline_seconds=$1; shift ;;
      --devhub-seconds) require_value "$devhub_option" "${1:-}"; devhub_elapsed_seconds=$1; shift ;;
      --outcome) require_value "$devhub_option" "${1:-}"; devhub_outcome=$1; shift ;;
      --reduction-band) require_value "$devhub_option" "${1:-}"; devhub_reduction_band=$1; shift ;;
      --cross-project) require_value "$devhub_option" "${1:-}"; devhub_cross_project=$1; shift ;;
      --failure) require_value "$devhub_option" "${1:-}"; devhub_failure=$1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "unknown option: $devhub_option" ;;
    esac
  done

  case "$devhub_project_slot" in
    p[1-9]*)
      devhub_project_number=${devhub_project_slot#p}
      case "$devhub_project_number" in *[!0-9]*|'')
        fail 'project slot must be an anonymous value such as p1 or p2'
      esac
      ;;
    *) fail 'project slot must be an anonymous value such as p1 or p2' ;;
  esac
  validate_enum tool "$devhub_tool" claude-code codex zcode opencode kimi gemini-cli github-copilot aider cline
  validate_enum 'session age' "$devhub_session_age" recent older
  validate_positive_integer 'baseline seconds' "$devhub_baseline_seconds"
  validate_positive_integer 'DevHub seconds' "$devhub_elapsed_seconds"
  validate_enum outcome "$devhub_outcome" correct wrong-project wrong-session unusable-context launch-failed
  validate_enum 'reduction band' "$devhub_reduction_band" 0 1-29 30-69 70-99 100
  validate_enum 'cross-project context' "$devhub_cross_project" no yes
  validate_enum failure "$devhub_failure" none path-missing session-not-found reader-unsupported \
    resume-unsupported wrong-binding stale-summary tool-launch other

  if test "$devhub_outcome" = correct && test "$devhub_failure" != none; then
    fail 'a correct outcome must use failure=none'
  fi
  if test "$devhub_outcome" != correct && test "$devhub_failure" = none; then
    fail 'an unsuccessful outcome must include a failure category'
  fi
  if test "$devhub_cross_project" = yes && test "$devhub_outcome" = correct; then
    fail 'cross-project context cannot be marked as a correct outcome'
  fi

  ensure_data_file
  devhub_attempt_id=$(awk 'END { print NR }' "$devhub_data_file")
  devhub_recorded_epoch=${DEVHUB_REENTRY_NOW_EPOCH:-$(date -u '+%s')}
  validate_positive_integer 'recorded epoch' "$devhub_recorded_epoch"
  if devhub_recorded_at=$(date -u -r "$devhub_recorded_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
    :
  else
    devhub_recorded_at=$(date -u -d "@$devhub_recorded_epoch" '+%Y-%m-%dT%H:%M:%SZ')
  fi
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$devhub_attempt_id" "$devhub_recorded_at" "$devhub_recorded_epoch" \
    "$devhub_project_slot" "$devhub_tool" \
    "$devhub_session_age" "$devhub_baseline_seconds" "$devhub_elapsed_seconds" \
    "$devhub_outcome" "$devhub_reduction_band" "$devhub_cross_project" "$devhub_failure" \
    >> "$devhub_data_file"
  printf 'Recorded privacy-safe re-entry attempt %s.\n' "$devhub_attempt_id"
}

summary() {
  ensure_data_file
  devhub_attempts=$(awk 'NR > 1 { count += 1 } END { print count + 0 }' "$devhub_data_file")
  if test "$devhub_attempts" -eq 0; then
    printf '%s\n' 'No re-entry attempts recorded yet.'
    exit 0
  fi

  devhub_summary_tmp=$(mktemp -d "${TMPDIR:-/tmp}/devhub-reentry-summary.XXXXXX")
  trap 'rm -rf "$devhub_summary_tmp"' EXIT HUP INT TERM

  awk -F, 'NR > 1 { print $7 }' "$devhub_data_file" | sort -n > "$devhub_summary_tmp/baseline"
  awk -F, 'NR > 1 { print $8 }' "$devhub_data_file" | sort -n > "$devhub_summary_tmp/devhub"
  awk -F, 'NR > 1 {
    if ($10 == "0") print 0
    else if ($10 == "1-29") print 15
    else if ($10 == "30-69") print 50
    else if ($10 == "70-99") print 85
    else if ($10 == "100") print 100
  }' "$devhub_data_file" | sort -n > "$devhub_summary_tmp/reduction"

  devhub_median_awk='{
    values[NR] = $1
  }
  END {
    if (NR % 2 == 1) printf "%.0f", values[(NR + 1) / 2]
    else printf "%.0f", (values[NR / 2] + values[NR / 2 + 1]) / 2
  }'
  devhub_baseline_median=$(awk "$devhub_median_awk" "$devhub_summary_tmp/baseline")
  devhub_elapsed_median=$(awk "$devhub_median_awk" "$devhub_summary_tmp/devhub")
  devhub_reduction_median=$(awk "$devhub_median_awk" "$devhub_summary_tmp/reduction")
  devhub_improvement=$(awk -v baseline="$devhub_baseline_median" -v elapsed="$devhub_elapsed_median" \
    'BEGIN { printf "%.0f", ((baseline - elapsed) * 100) / baseline }')

  devhub_correct=$(awk -F, 'NR > 1 && $9 == "correct" { count += 1 } END { print count + 0 }' "$devhub_data_file")
  devhub_cross_project=$(awk -F, 'NR > 1 && $11 == "yes" { count += 1 } END { print count + 0 }' "$devhub_data_file")
  devhub_projects=$(awk -F, 'NR > 1 && !seen[$4]++ { count += 1 } END { print count + 0 }' "$devhub_data_file")
  devhub_tools=$(awk -F, 'NR > 1 && !seen[$5]++ { count += 1 } END { print count + 0 }' "$devhub_data_file")
  devhub_recent=$(awk -F, 'NR > 1 && $6 == "recent" { count += 1 } END { print count + 0 }' "$devhub_data_file")
  devhub_older=$(awk -F, 'NR > 1 && $6 == "older" { count += 1 } END { print count + 0 }' "$devhub_data_file")
  devhub_span_days=$(awk -F, 'NR > 1 {
      if (!seen) { minimum = $3; maximum = $3; seen = 1 }
      else {
        if ($3 < minimum) minimum = $3
        if ($3 > maximum) maximum = $3
      }
    }
    END { print int((maximum - minimum) / 86400) + 1 }' "$devhub_data_file")
  devhub_correct_percent=$(awk -v correct="$devhub_correct" -v attempts="$devhub_attempts" \
    'BEGIN { printf "%.0f", (correct * 100) / attempts }')

  devhub_trial_gate='PENDING'
  if test "$devhub_attempts" -ge 10 && test "$devhub_projects" -ge 3 && test "$devhub_tools" -ge 2 \
    && test "$devhub_recent" -gt 0 && test "$devhub_older" -gt 0 && test "$devhub_span_days" -ge 7; then
    devhub_trial_gate='COVERAGE MET'
  fi
  devhub_outcome_gate='NOT MET'
  test "$devhub_trial_gate" = 'COVERAGE MET' \
    && test "$devhub_correct_percent" -ge 90 && test "$devhub_elapsed_median" -le 60 \
    && test "$devhub_improvement" -ge 50 && test "$devhub_reduction_median" -ge 70 \
    && test "$devhub_cross_project" -eq 0 && devhub_outcome_gate='TARGETS MET'
  devhub_day_label=days
  test "$devhub_span_days" -eq 1 && devhub_day_label=day

  printf '%s\n' \
    'CodeReentry privacy-safe re-entry summary' \
    "Attempts: $devhub_attempts (coverage gate: $devhub_trial_gate)" \
    "Recorded span: $devhub_span_days $devhub_day_label" \
    "Anonymous project slots: $devhub_projects; tools: $devhub_tools; recent: $devhub_recent; older: $devhub_older" \
    "Correct project/session/context: $devhub_correct/$devhub_attempts ($devhub_correct_percent%)" \
    "Median time: ${devhub_elapsed_median}s with CodeReentry vs ${devhub_baseline_median}s baseline; relative improvement: $devhub_improvement%" \
    "Approximate median repeated-background reduction: $devhub_reduction_median%" \
    "Cross-project context incidents: $devhub_cross_project" \
    "Initial outcome targets: $devhub_outcome_gate" \
    '' \
    'Failure categories:'
  awk -F, 'NR > 1 && $12 != "none" { failures[$12] += 1 }
    END {
      found = 0
      for (failure in failures) { print "- " failure ": " failures[failure]; found = 1 }
      if (!found) print "- none"
    }' "$devhub_data_file" | sort
}

case "${1:-}" in
  record) shift; record_trial "$@" ;;
  summary) shift; test "$#" -eq 0 || fail 'summary accepts no additional arguments'; summary ;;
  -h|--help) usage ;;
  '') usage; exit 64 ;;
  *) fail "unknown command: $1" ;;
esac
