#!/bin/sh
set -eu

devhub_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
devhub_temp=$(mktemp -d "${TMPDIR:-/tmp}/devhub-performance-summary.XXXXXX")
cleanup() {
  rm -rf "$devhub_temp"
}
trap cleanup EXIT HUP INT TERM

cat > "$devhub_temp/samples.csv" <<'EOF'
elapsed_seconds,phase,rss_kb,cpu_percent,physical_footprint_bytes,peak_physical_footprint_bytes
0,launch,1024,5.0,1048576,1048576
1,idle,2048,0.0,2097152,2097152
2,initial-scan,3072,20.0,3145728,3145728
3,cycle-01,4096,10.0,4194304,4194304
4,cycle-10,4300,10.0,4403200,4403200
5,recovery,3000,0.0,3072000,4403200
EOF
cat > "$devhub_temp/scenario.json" <<'EOF'
{
  "schemaVersion": 1,
  "succeeded": true,
  "fixtureScale": "small",
  "cycles": 10,
  "projectCount": 5,
  "sessionCount": 100,
  "idleSeconds": 300,
  "initialScanMilliseconds": 50,
  "repeatedRefreshMilliseconds": [10, 11, 12, 13, 14, 15, 16, 17, 18, 19],
  "navigationTransitions": 120,
  "settingsWindowOpenCount": 10,
  "recoverySeconds": 10,
  "failureCode": null
}
EOF

ruby "$devhub_repo_root/scripts/summarize-performance.rb" \
  "$devhub_temp/samples.csv" \
  "$devhub_temp/scenario.json" \
  "$devhub_repo_root/scripts/performance-budget.json" \
  > "$devhub_temp/summary.txt"
grep -q '^budget: PASS$' "$devhub_temp/summary.txt"
grep -q '^clean launch peak RSS: 4.2 MiB$' "$devhub_temp/summary.txt"
grep -q '^idle final CPU: 0.0 %$' "$devhub_temp/summary.txt"

cat > "$devhub_temp/failing-budget.json" <<'EOF'
{
  "small": {
    "initial_scan_milliseconds": 1,
    "refresh_p95_milliseconds": 1,
    "peak_rss_mb": 1,
    "peak_physical_mb": 1,
    "recovery_rss_mb": 1,
    "cycle_growth_percent": 1
  }
}
EOF
if ruby "$devhub_repo_root/scripts/summarize-performance.rb" \
  "$devhub_temp/samples.csv" \
  "$devhub_temp/scenario.json" \
  "$devhub_temp/failing-budget.json" \
  > "$devhub_temp/failing-summary.txt"; then
  echo "error: failing performance budget unexpectedly passed" >&2
  exit 1
fi
grep -q '^budget: FAIL$' "$devhub_temp/failing-summary.txt"

if "$devhub_repo_root/scripts/performance-baseline.sh" --cycles 0 \
  > "$devhub_temp/invalid.out" 2>&1; then
  echo "error: invalid baseline bounds unexpectedly passed" >&2
  exit 1
fi
grep -q 'cycles must be between 1 and 100' "$devhub_temp/invalid.out"

echo "performance summary tests: passed"
