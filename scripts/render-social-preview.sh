#!/bin/sh
set -eu

devhub_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
devhub_source="file://$devhub_repo_root/docs/assets/social-preview.html"
devhub_output="$devhub_repo_root/docs/assets/social-preview.png"

command -v npx >/dev/null 2>&1 || {
  echo "error: Node.js and npx are required" >&2
  exit 1
}

if [ -d "/Applications/Google Chrome.app" ]; then
  npx --yes playwright@latest screenshot \
    --channel=chrome \
    --viewport-size="1280,640" \
    "$devhub_source" \
    "$devhub_output"
else
  npx --yes playwright@latest install --only-shell --no-progress chromium
  npx --yes playwright@latest screenshot \
    --viewport-size="1280,640" \
    "$devhub_source" \
    "$devhub_output"
fi

echo "Rendered $devhub_output"
