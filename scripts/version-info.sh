#!/bin/sh
set -eu

devhub_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
devhub_project=${CODEREENTRY_PROJECT_YML:-"$devhub_root/project.yml"}

case "${1:-}" in
  marketing) devhub_key=MARKETING_VERSION ;;
  build) devhub_key=CURRENT_PROJECT_VERSION ;;
  *)
    echo "usage: $0 marketing|build" >&2
    exit 64
    ;;
esac

test -f "$devhub_project" || {
  echo "error: project definition not found: $devhub_project" >&2
  exit 1
}

devhub_value=$(
  sed -nE \
    "s/^[[:space:]]*$devhub_key:[[:space:]]*\"([^\"]+)\"[[:space:]]*$/\1/p" \
    "$devhub_project"
)
devhub_count=$(printf '%s\n' "$devhub_value" | awk 'NF { count += 1 } END { print count + 0 }')
if [ "$devhub_count" -ne 1 ]; then
  echo "error: expected exactly one quoted $devhub_key in $devhub_project" >&2
  exit 1
fi

printf '%s\n' "$devhub_value"
