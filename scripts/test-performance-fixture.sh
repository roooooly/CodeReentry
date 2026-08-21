#!/bin/sh
set -eu

devhub_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
devhub_fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/devhub-performance-fixture-test.XXXXXX")
devhub_empty_fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/devhub-empty-performance-fixture-test.XXXXXX")
trap 'rm -rf "$devhub_fixture_root" "$devhub_empty_fixture_root"' EXIT HUP INT TERM

swift run --quiet --package-path "$devhub_repo_root/DevHubPackage" \
  DevHubFixtureTool create --profile "$devhub_fixture_root" --scale small
swift run --quiet --package-path "$devhub_repo_root/DevHubPackage" \
  DevHubFixtureTool verify --profile "$devhub_fixture_root" --scale small

swift run --quiet --package-path "$devhub_repo_root/DevHubPackage" \
  DevHubFixtureTool create --profile "$devhub_empty_fixture_root" --scale small --index-state empty
swift run --quiet --package-path "$devhub_repo_root/DevHubPackage" \
  DevHubFixtureTool verify --profile "$devhub_empty_fixture_root" --scale small --index-state empty

if swift run --quiet --package-path "$devhub_repo_root/DevHubPackage" \
  DevHubFixtureTool create --profile "$devhub_fixture_root" --scale small >/dev/null 2>&1; then
  printf '%s\n' 'error: fixture tool overwrote an existing profile' >&2
  exit 1
fi

printf '%s\n' 'performance fixture tests: passed'
