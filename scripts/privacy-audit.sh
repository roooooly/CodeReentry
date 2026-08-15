#!/bin/sh
set -eu

devhub_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$devhub_repo_root"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "privacy-audit: run this script inside the DevHub Git repository" >&2
  exit 1
fi

devhub_failed=0

devhub_sensitive_files=$(git ls-files | rg -i '(^|/)(\.env($|\.)|.*\.(jsonl|sqlite|sqlite3|db|log|trace|xcresult|pem|key|p12|pfx|cer|crt|mobileprovision|dmg|zip)$|xcuserdata/|DerivedData/|build/|dist/|\.spm-packages/|\.build/)' || true)
if test -n "$devhub_sensitive_files"; then
  echo "privacy-audit: sensitive or generated files are tracked:" >&2
  echo "$devhub_sensitive_files" >&2
  devhub_failed=1
fi

devhub_private_paths=$(git grep -n -I -E '/Users/[^/[:space:]"]+|/home/[^/[:space:]"]+' -- . ':!scripts/privacy-audit.sh' 2>/dev/null \
  | rg -P '/Users/(?!example(?:-[^/\s"]+)?(?:/|["\s]|$))[^/\s"]+|/home/(?!example(?:-[^/\s"]+)?(?:/|["\s]|$))[^/\s"]+' \
  || true)
if test -n "$devhub_private_paths"; then
  echo "privacy-audit: user-specific absolute paths found:" >&2
  echo "$devhub_private_paths" >&2
  devhub_failed=1
fi

devhub_local_user=$(id -un)
# CI accounts use generic names such as "runner", which occur legitimately in source
# identifiers. The local identity check is useful on a developer Mac; the path,
# legacy-identity, and credential checks below remain active everywhere.
if test "${CI:-}" != "true" && test "$devhub_local_user" != "example"; then
  devhub_identity_hits=$(git grep -n -I -i -F "$devhub_local_user" -- . ':!scripts/privacy-audit.sh' 2>/dev/null || true)
  if test -n "$devhub_identity_hits"; then
    echo "privacy-audit: current macOS username appears in tracked content:" >&2
    echo "$devhub_identity_hits" >&2
    devhub_failed=1
  fi
fi

devhub_legacy_identity=$(git grep -n -I -E 'com\.crispin\.devhub|/Users/crispin|Projects/(EMC|cat|doctor|timecrash)(/|"|$)' -- . ':!scripts/privacy-audit.sh' 2>/dev/null || true)
if test -n "$devhub_legacy_identity"; then
  echo "privacy-audit: legacy private identifiers found:" >&2
  echo "$devhub_legacy_identity" >&2
  devhub_failed=1
fi

devhub_secret_hits=$(git grep -n -I -E 'github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{25,}|BEGIN ([A-Z ]+ )?PRIVATE KEY' -- . \
  ':!scripts/privacy-audit.sh' \
  ':!DevHubPackage/Tests/DevHubCoreTests/Injection/InjectionManagerTests.swift' \
  ':!DevHubPackage/Tests/DevHubCoreTests/LoggerTests.swift' \
  ':!DevHubPackage/Tests/DevHubCoreTests/Security/SecretScannerTests.swift' \
  ':!Tests/UITests/Infrastructure/SettingsSystemServicesTests.swift' \
  ':!Tests/UITests/LauncherIntegrationTests.swift' \
  ':!Tests/UITests/ToolsTabTests.swift' 2>/dev/null || true)
if test -n "$devhub_secret_hits"; then
  echo "privacy-audit: credential-shaped text found outside dedicated tests:" >&2
  echo "$devhub_secret_hits" >&2
  devhub_failed=1
fi

if test "$devhub_failed" -ne 0; then
  exit 1
fi

echo "privacy-audit: passed"
