#!/bin/sh
set -eu

devhub_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
devhub_scale=medium
devhub_cycles=10
devhub_idle_seconds=300
devhub_recovery_seconds=10
devhub_sample_interval=1
devhub_output=""

usage() {
  cat <<'EOF'
Usage: ./scripts/performance-baseline.sh [options]

Run DevHub's deterministic performance scenario in a disposable macOS profile.
No real project paths, session histories, prompts, or credentials are read.

Options:
  --scale small|medium|large  Fixture size (default: medium)
  --cycles N                 Refresh/navigation cycles, 1-100 (default: 10)
  --idle-seconds N           Pre-scan idle observation, 0-600 (default: 300)
  --recovery-seconds N       Post-operation recovery, 0-300 (default: 10)
  --sample-interval N        Sampling interval in seconds, 1-10 (default: 1)
  --output DIR               Durable report directory (default: ignored local-data/)
EOF
}

require_integer_between() {
  devhub_value=$1
  devhub_min=$2
  devhub_max=$3
  devhub_label=$4
  case "$devhub_value" in
    ''|*[!0-9]*)
      echo "error: $devhub_label must be an integer" >&2
      exit 64
      ;;
  esac
  if [ "$devhub_value" -lt "$devhub_min" ] || [ "$devhub_value" -gt "$devhub_max" ]; then
    echo "error: $devhub_label must be between $devhub_min and $devhub_max" >&2
    exit 64
  fi
}

while [ "$#" -gt 0 ]; do
  devhub_option=$1
  shift
  case "$devhub_option" in
    -h|--help)
      usage
      exit 0
      ;;
    --scale|--cycles|--idle-seconds|--recovery-seconds|--sample-interval|--output)
      if [ "$#" -eq 0 ]; then
        echo "error: $devhub_option requires a value" >&2
        exit 64
      fi
      devhub_value=$1
      shift
      case "$devhub_option" in
        --scale) devhub_scale=$devhub_value ;;
        --cycles) devhub_cycles=$devhub_value ;;
        --idle-seconds) devhub_idle_seconds=$devhub_value ;;
        --recovery-seconds) devhub_recovery_seconds=$devhub_value ;;
        --sample-interval) devhub_sample_interval=$devhub_value ;;
        --output) devhub_output=$devhub_value ;;
      esac
      ;;
    *)
      echo "error: unknown option: $devhub_option" >&2
      usage >&2
      exit 64
      ;;
  esac
done

case "$devhub_scale" in
  small|medium|large) ;;
  *)
    echo "error: scale must be small, medium, or large" >&2
    exit 64
    ;;
esac
require_integer_between "$devhub_cycles" 1 100 cycles
require_integer_between "$devhub_idle_seconds" 0 600 idle-seconds
require_integer_between "$devhub_recovery_seconds" 0 300 recovery-seconds
require_integer_between "$devhub_sample_interval" 1 10 sample-interval

command -v swift >/dev/null 2>&1 || {
  echo "error: Swift is required" >&2
  exit 1
}
command -v footprint >/dev/null 2>&1 || {
  echo "error: macOS footprint is required" >&2
  exit 1
}
command -v ruby >/dev/null 2>&1 || {
  echo "error: Ruby is required to summarize the report" >&2
  exit 1
}

if [ -z "$devhub_output" ]; then
  devhub_stamp=$(date -u +%Y%m%dT%H%M%SZ)
  devhub_output="$devhub_repo_root/local-data/performance/$devhub_stamp-$devhub_scale"
fi
if [ -L "$devhub_output" ] || [ -e "$devhub_output" ]; then
  echo "error: output path already exists or is a symlink: $devhub_output" >&2
  exit 1
fi
mkdir -p "$devhub_output"
chmod 700 "$devhub_output"

devhub_profile=$(mktemp -d "${TMPDIR:-/tmp}/devhub-performance.XXXXXX")
devhub_pid=""
cleanup() {
  if [ -n "$devhub_pid" ] && kill -0 "$devhub_pid" 2>/dev/null; then
    kill -TERM "$devhub_pid" 2>/dev/null || true
    wait "$devhub_pid" 2>/dev/null || true
  fi
  rm -rf "$devhub_profile"
}
trap cleanup EXIT HUP INT TERM

echo "Building the verified Release app…"
"$devhub_repo_root/scripts/run-source.sh" --build-only
devhub_derived_data=${DEVHUB_DERIVED_DATA_PATH:-"$devhub_repo_root/build/SourceDerivedData"}
devhub_app="$devhub_derived_data/Build/Products/Release/CodeReentry.app"
devhub_executable="$devhub_app/Contents/MacOS/CodeReentry"
test -x "$devhub_executable"

echo "Building and creating the $devhub_scale deterministic fixture…"
swift build \
  --package-path "$devhub_repo_root/DevHubPackage" \
  -c release \
  --product DevHubFixtureTool
devhub_bin_path=$(swift build \
  --package-path "$devhub_repo_root/DevHubPackage" \
  -c release \
  --show-bin-path)
"$devhub_bin_path/DevHubFixtureTool" create \
  --profile "$devhub_profile" \
  --scale "$devhub_scale" \
  --index-state empty

devhub_scenario_dir="$devhub_profile/Library/Application Support/DevHub/PerformanceScenario"
mkdir -p "$devhub_scenario_dir"
printf 'launch\n' > "$devhub_scenario_dir/phase.txt"

devhub_samples="$devhub_output/samples.csv"
printf 'elapsed_seconds,phase,rss_kb,cpu_percent,physical_footprint_bytes,peak_physical_footprint_bytes\n' > "$devhub_samples"
chmod 600 "$devhub_samples"

echo "Launching only the isolated profile; durable files contain aggregate metrics only…"
CFFIXED_USER_HOME="$devhub_profile" \
HOME="$devhub_profile" \
DEVHUB_PERFORMANCE_SCENARIO=1 \
DEVHUB_PERFORMANCE_PROFILE="$devhub_profile" \
DEVHUB_PERFORMANCE_CYCLES="$devhub_cycles" \
DEVHUB_PERFORMANCE_IDLE_SECONDS="$devhub_idle_seconds" \
DEVHUB_PERFORMANCE_RECOVERY_SECONDS="$devhub_recovery_seconds" \
"$devhub_executable" -devhub.onboarding.completed YES \
  > "$devhub_profile/app.log" 2>&1 &
devhub_pid=$!
devhub_started_at=$(date +%s)
devhub_timeout=$((devhub_idle_seconds + devhub_recovery_seconds + devhub_cycles * 8 + 180))

while kill -0 "$devhub_pid" 2>/dev/null; do
  devhub_now=$(date +%s)
  devhub_elapsed=$((devhub_now - devhub_started_at))
  if [ "$devhub_elapsed" -gt "$devhub_timeout" ]; then
    echo "error: performance scenario exceeded the ${devhub_timeout}s safety timeout" >&2
    kill -TERM "$devhub_pid" 2>/dev/null || true
    wait "$devhub_pid" 2>/dev/null || true
    devhub_pid=""
    exit 1
  fi

  devhub_phase=$(sed -n '1p' "$devhub_scenario_dir/phase.txt" 2>/dev/null || true)
  case "$devhub_phase" in
    launch|idle|initial-scan|warmup|cycle-[0-9][0-9]|recovery|complete|failed) ;;
    *) devhub_phase=unknown ;;
  esac
  devhub_process=$(ps -p "$devhub_pid" -o rss= -o %cpu= 2>/dev/null || true)
  devhub_rss=$(printf '%s\n' "$devhub_process" | awk '{print $1; exit}')
  devhub_cpu=$(printf '%s\n' "$devhub_process" | awk '{print $2; exit}')
  devhub_footprint=$(footprint -p "$devhub_pid" --noCategories -f bytes 2>/dev/null || true)
  devhub_physical=$(printf '%s\n' "$devhub_footprint" | awk '/^[[:space:]]*phys_footprint:/ {print $(NF - 1); exit}')
  devhub_peak=$(printf '%s\n' "$devhub_footprint" | awk '/^[[:space:]]*phys_footprint_peak:/ {print $(NF - 1); exit}')
  devhub_rss=${devhub_rss:-0}
  devhub_cpu=${devhub_cpu:-0}
  devhub_physical=${devhub_physical:-0}
  devhub_peak=${devhub_peak:-0}
  printf '%s,%s,%s,%s,%s,%s\n' \
    "$devhub_elapsed" "$devhub_phase" "$devhub_rss" "$devhub_cpu" \
    "$devhub_physical" "$devhub_peak" >> "$devhub_samples"
  sleep "$devhub_sample_interval"
done

devhub_status=0
wait "$devhub_pid" || devhub_status=$?
devhub_pid=""
if [ "$devhub_status" -ne 0 ]; then
  echo "error: isolated DevHub scenario exited with status $devhub_status" >&2
  exit 1
fi

devhub_report="$devhub_scenario_dir/report.json"
test -f "$devhub_report" || {
  echo "error: scenario did not produce report.json" >&2
  exit 1
}
cp "$devhub_report" "$devhub_output/scenario.json"
chmod 600 "$devhub_output/scenario.json"

{
  printf '{\n'
  printf '  "architecture": "%s",\n' "$(uname -m)"
  printf '  "macOSVersion": "%s",\n' "$(sw_vers -productVersion)"
  printf '  "configuration": "Release",\n'
  printf '  "scale": "%s",\n' "$devhub_scale"
  printf '  "sampleIntervalSeconds": %s\n' "$devhub_sample_interval"
  printf '}\n'
} > "$devhub_output/system.json"
chmod 600 "$devhub_output/system.json"

devhub_summary_status=0
ruby "$devhub_repo_root/scripts/summarize-performance.rb" \
    "$devhub_samples" \
    "$devhub_output/scenario.json" \
    "$devhub_repo_root/scripts/performance-budget.json" \
    > "$devhub_output/summary.txt" || devhub_summary_status=$?
chmod 600 "$devhub_output/summary.txt"

cat "$devhub_output/summary.txt"
echo "Aggregate report: $devhub_output"
exit "$devhub_summary_status"
