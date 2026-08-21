#!/bin/bash
set -euo pipefail

DEVHUB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVHUB_SOURCE_APP="${DEVHUB_SOURCE_APP:-$DEVHUB_ROOT/build/SourceDerivedData/Build/Products/Release/CodeReentry.app}"

if [[ ! -d "$DEVHUB_SOURCE_APP" ]]; then
  echo "error: source app is missing; run ./scripts/run-source.sh --build-only first" >&2
  exit 1
fi

DEVHUB_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codereentry-source-install.XXXXXX")"
trap 'rm -rf -- "$DEVHUB_TEST_ROOT"' EXIT
DEVHUB_INSTALL_DIRECTORY="$DEVHUB_TEST_ROOT/Applications With Space"
DEVHUB_DESTINATION="$DEVHUB_INSTALL_DIRECTORY/CodeReentry.app"

"$DEVHUB_ROOT/scripts/install-source-app.sh" "$DEVHUB_SOURCE_APP" "$DEVHUB_INSTALL_DIRECTORY"
test -d "$DEVHUB_DESTINATION"
"$DEVHUB_ROOT/scripts/verify-release.sh" "$DEVHUB_DESTINATION" "$(uname -m)"

touch "$DEVHUB_DESTINATION/Contents/Resources/replaced-copy-marker"
"$DEVHUB_ROOT/scripts/install-source-app.sh" "$DEVHUB_SOURCE_APP" "$DEVHUB_INSTALL_DIRECTORY"
test ! -e "$DEVHUB_DESTINATION/Contents/Resources/replaced-copy-marker"

/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier example.invalid.foreign-app' \
  "$DEVHUB_DESTINATION/Contents/Info.plist"
touch "$DEVHUB_DESTINATION/Contents/Resources/foreign-copy-marker"
if "$DEVHUB_ROOT/scripts/install-source-app.sh" \
  "$DEVHUB_SOURCE_APP" "$DEVHUB_INSTALL_DIRECTORY" >/dev/null 2>&1; then
  echo "error: installer replaced a foreign bundle" >&2
  exit 1
fi
test -e "$DEVHUB_DESTINATION/Contents/Resources/foreign-copy-marker"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEVHUB_DESTINATION/Contents/Info.plist")" = \
  "example.invalid.foreign-app"

DEVHUB_LINK_ROOT="$DEVHUB_TEST_ROOT/link-root"
ln -s "$DEVHUB_INSTALL_DIRECTORY" "$DEVHUB_LINK_ROOT"
if "$DEVHUB_ROOT/scripts/install-source-app.sh" \
  "$DEVHUB_SOURCE_APP" "$DEVHUB_LINK_ROOT" >/dev/null 2>&1; then
  echo "error: installer accepted a symbolic-link install directory" >&2
  exit 1
fi

DEVHUB_LINK_DESTINATION_DIRECTORY="$DEVHUB_TEST_ROOT/link-destination"
DEVHUB_FOREIGN_TARGET="$DEVHUB_TEST_ROOT/foreign-target.app"
mkdir -p "$DEVHUB_LINK_DESTINATION_DIRECTORY" "$DEVHUB_FOREIGN_TARGET"
ln -s "$DEVHUB_FOREIGN_TARGET" \
  "$DEVHUB_LINK_DESTINATION_DIRECTORY/CodeReentry.app"
if "$DEVHUB_ROOT/scripts/install-source-app.sh" \
  "$DEVHUB_SOURCE_APP" "$DEVHUB_LINK_DESTINATION_DIRECTORY" >/dev/null 2>&1; then
  echo "error: installer accepted a symbolic-link app destination" >&2
  exit 1
fi
test -L "$DEVHUB_LINK_DESTINATION_DIRECTORY/CodeReentry.app"

echo "source install tests: passed"
