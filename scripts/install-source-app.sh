#!/bin/bash
set -euo pipefail

DEVHUB_SOURCE_APP="${1:-}"
DEVHUB_INSTALL_DIRECTORY="${2:-${CODEREENTRY_INSTALL_DIRECTORY:-${HOME:?}/Applications}}"

if [[ -z "$DEVHUB_SOURCE_APP" || ! -d "$DEVHUB_SOURCE_APP" ]]; then
  echo "usage: $0 /path/to/CodeReentry.app [/absolute/install/directory]" >&2
  exit 64
fi

case "$DEVHUB_INSTALL_DIRECTORY" in
  /*) ;;
  *)
    echo "error: install directory must be an absolute path" >&2
    exit 64
    ;;
esac

DEVHUB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVHUB_VERIFY="$DEVHUB_ROOT/scripts/verify-release.sh"
DEVHUB_EXPECTED_ID="io.github.roooooly.devhub"

"$DEVHUB_VERIFY" "$DEVHUB_SOURCE_APP" "$(uname -m)"

if [[ -L "$DEVHUB_INSTALL_DIRECTORY" ]]; then
  echo "error: install directory must not be a symbolic link" >&2
  exit 1
fi
mkdir -p "$DEVHUB_INSTALL_DIRECTORY"
DEVHUB_INSTALL_DIRECTORY="$(cd "$DEVHUB_INSTALL_DIRECTORY" && pwd -P)"
DEVHUB_DESTINATION="$DEVHUB_INSTALL_DIRECTORY/CodeReentry.app"
DEVHUB_SOURCE_REAL="$(cd "$(dirname "$DEVHUB_SOURCE_APP")" && pwd -P)/$(basename "$DEVHUB_SOURCE_APP")"

if [[ "$DEVHUB_SOURCE_REAL" == "$DEVHUB_DESTINATION" ]]; then
  echo "error: source and installed app must be different paths" >&2
  exit 64
fi

if [[ -L "$DEVHUB_DESTINATION" ]]; then
  echo "error: refusing to replace a symbolic link at $DEVHUB_DESTINATION" >&2
  exit 1
fi
if [[ -e "$DEVHUB_DESTINATION" && ! -d "$DEVHUB_DESTINATION" ]]; then
  echo "error: refusing to replace a non-app item at $DEVHUB_DESTINATION" >&2
  exit 1
fi
if [[ -d "$DEVHUB_DESTINATION" ]]; then
  DEVHUB_EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEVHUB_DESTINATION/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$DEVHUB_EXISTING_ID" != "$DEVHUB_EXPECTED_ID" ]]; then
    echo "error: refusing to replace an app with bundle id '${DEVHUB_EXISTING_ID:-<missing>}'" >&2
    exit 1
  fi
fi

DEVHUB_STAGE="$(mktemp -d "$DEVHUB_INSTALL_DIRECTORY/.codereentry-install.XXXXXX")"
DEVHUB_STAGED_APP="$DEVHUB_STAGE/CodeReentry.app"
DEVHUB_PREVIOUS_APP="$DEVHUB_STAGE/previous.app"
DEVHUB_COMMITTED=false
DEVHUB_PLACED=false
DEVHUB_REPLACED=false

cleanup() {
  if [[ "$DEVHUB_COMMITTED" != true ]]; then
    if [[ "$DEVHUB_PLACED" == true && -d "$DEVHUB_DESTINATION" ]]; then
      rm -rf -- "$DEVHUB_DESTINATION"
    fi
    if [[ ! -e "$DEVHUB_DESTINATION" && -d "$DEVHUB_PREVIOUS_APP" ]]; then
      mv "$DEVHUB_PREVIOUS_APP" "$DEVHUB_DESTINATION" || true
    fi
  fi
  rm -rf -- "$DEVHUB_STAGE"
}
trap cleanup EXIT INT TERM

ditto "$DEVHUB_SOURCE_APP" "$DEVHUB_STAGED_APP"
"$DEVHUB_VERIFY" "$DEVHUB_STAGED_APP" "$(uname -m)"

if [[ -d "$DEVHUB_DESTINATION" ]]; then
  mv "$DEVHUB_DESTINATION" "$DEVHUB_PREVIOUS_APP"
  DEVHUB_REPLACED=true
fi

if ! mv "$DEVHUB_STAGED_APP" "$DEVHUB_DESTINATION"; then
  echo "error: could not place CodeReentry in $DEVHUB_INSTALL_DIRECTORY" >&2
  exit 1
fi
DEVHUB_PLACED=true

if ! "$DEVHUB_VERIFY" "$DEVHUB_DESTINATION" "$(uname -m)"; then
  echo "error: installed app did not pass verification; restoring the previous copy" >&2
  exit 1
fi

DEVHUB_COMMITTED=true
rm -rf -- "$DEVHUB_STAGE"
trap - EXIT INT TERM

if [[ "$DEVHUB_REPLACED" == true ]]; then
  echo "Replaced the previous verified CodeReentry source installation."
fi
echo "Installed verified local source build: $DEVHUB_DESTINATION"
