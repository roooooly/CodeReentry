#!/bin/bash
set -euo pipefail

DEVHUB_APP="${1:-}"
DEVHUB_EXPECTED_ARCH="${2:-arm64}"
if [[ -z "$DEVHUB_APP" || ! -d "$DEVHUB_APP" ]]; then
  echo "usage: $0 /path/to/CodeReentry.app [arm64|x86_64]" >&2
  exit 64
fi

case "$DEVHUB_EXPECTED_ARCH" in
  arm64|x86_64) ;;
  *)
    echo "error: unsupported expected architecture: $DEVHUB_EXPECTED_ARCH" >&2
    exit 64
    ;;
esac

DEVHUB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVHUB_SOURCE_PLIST="$DEVHUB_ROOT/DevHub/Info.plist"
DEVHUB_BUNDLE_PLIST="$DEVHUB_APP/Contents/Info.plist"
DEVHUB_VERSION_INFO="$DEVHUB_ROOT/scripts/version-info.sh"

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

optional_plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

require_equal() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: $label must be '$expected' (found '${actual:-<missing>}')" >&2
    exit 1
  fi
}

require_equal "$(plist_value "$DEVHUB_SOURCE_PLIST" CFBundleShortVersionString)" '$(MARKETING_VERSION)' "source marketing-version placeholder"
require_equal "$(plist_value "$DEVHUB_SOURCE_PLIST" CFBundleVersion)" '$(CURRENT_PROJECT_VERSION)' "source build-version placeholder"
DEVHUB_EXPECTED_VERSION="$("$DEVHUB_VERSION_INFO" marketing)"
DEVHUB_EXPECTED_BUILD="$("$DEVHUB_VERSION_INFO" build)"
DEVHUB_EXPECTED_MINIMUM_SYSTEM="$(plist_value "$DEVHUB_SOURCE_PLIST" LSMinimumSystemVersion)"

require_equal "$(optional_plist_value "$DEVHUB_BUNDLE_PLIST" CFBundleIdentifier)" "io.github.roooooly.devhub" "bundle identifier"
require_equal "$(optional_plist_value "$DEVHUB_BUNDLE_PLIST" CFBundleExecutable)" "CodeReentry" "bundle executable"
require_equal "$(optional_plist_value "$DEVHUB_BUNDLE_PLIST" CFBundlePackageType)" "APPL" "bundle package type"
require_equal "$(optional_plist_value "$DEVHUB_BUNDLE_PLIST" CFBundleShortVersionString)" "$DEVHUB_EXPECTED_VERSION" "marketing version"
require_equal "$(optional_plist_value "$DEVHUB_BUNDLE_PLIST" CFBundleVersion)" "$DEVHUB_EXPECTED_BUILD" "build version"
require_equal "$(optional_plist_value "$DEVHUB_BUNDLE_PLIST" LSMinimumSystemVersion)" "$DEVHUB_EXPECTED_MINIMUM_SYSTEM" "minimum macOS version"

if /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$DEVHUB_BUNDLE_PLIST" >/dev/null 2>&1; then
  echo "error: local release must not include SUFeedURL" >&2
  exit 1
fi

test -x "$DEVHUB_APP/Contents/MacOS/CodeReentry"
if ! codesign --verify --deep --strict=all "$DEVHUB_APP" >/dev/null 2>&1; then
  codesign --verify --deep --strict=all --verbose=4 "$DEVHUB_APP"
  exit 1
fi

DEVHUB_SIGNING_INFO="$(codesign -dv --verbose=4 "$DEVHUB_APP" 2>&1)"
DEVHUB_CODE_DIRECTORY="$(printf '%s\n' "$DEVHUB_SIGNING_INFO" | sed -n '/^CodeDirectory /{p;q;}')"
if [[ "$DEVHUB_CODE_DIRECTORY" != *"runtime"* ]]; then
  echo "error: Release app must enable the hardened runtime" >&2
  exit 1
fi

DEVHUB_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/devhub-entitlements.XXXXXX")"
trap 'rm -f "$DEVHUB_ENTITLEMENTS"' EXIT
codesign -d --xml --entitlements - "$DEVHUB_APP" \
  > "$DEVHUB_ENTITLEMENTS" 2>/dev/null

test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.automation.apple-events' "$DEVHUB_ENTITLEMENTS")" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.disable-library-validation' "$DEVHUB_ENTITLEMENTS")" = "true"
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$DEVHUB_ENTITLEMENTS" >/dev/null 2>&1; then
  test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$DEVHUB_ENTITLEMENTS")" = "false" || {
    echo "error: Release app must not include get-task-allow=true" >&2
    exit 1
  }
fi

DEVHUB_ARCHS="$(lipo -archs "$DEVHUB_APP/Contents/MacOS/CodeReentry")"
[[ " $DEVHUB_ARCHS " == *" $DEVHUB_EXPECTED_ARCH "* ]] || {
  echo "error: $DEVHUB_EXPECTED_ARCH slice missing ($DEVHUB_ARCHS)" >&2
  exit 1
}

test -f "$DEVHUB_APP/Contents/Resources/AppIcon.icns"
echo "Verified CodeReentry.app (architectures: $DEVHUB_ARCHS)"
