#!/bin/bash
set -euo pipefail

DEVHUB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVHUB_DERIVED="$DEVHUB_ROOT/build/ReleaseDerivedData"
DEVHUB_DIST="$DEVHUB_ROOT/dist"
DEVHUB_VERSION="$("$DEVHUB_ROOT/scripts/version-info.sh" marketing)"
DEVHUB_APP="$DEVHUB_DERIVED/Build/Products/Release/CodeReentry.app"
DEVHUB_BASENAME="CodeReentry-$DEVHUB_VERSION-arm64"

command -v xcodegen >/dev/null || {
  echo "error: xcodegen is required (brew install xcodegen)" >&2
  exit 1
}

cd "$DEVHUB_ROOT"
xcodegen generate

xcodebuild \
  -project DevHub.xcodeproj \
  -scheme DevHub \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DEVHUB_DERIVED" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  CODE_SIGN_ENTITLEMENTS=DevHub.local-release.entitlements \
  build

test -d "$DEVHUB_APP"
"$DEVHUB_ROOT/scripts/verify-release.sh" "$DEVHUB_APP"

mkdir -p "$DEVHUB_DIST"
DEVHUB_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/devhub-release.XXXXXX")"
trap 'rm -rf "$DEVHUB_STAGE"' EXIT

ditto "$DEVHUB_APP" "$DEVHUB_STAGE/CodeReentry.app"
ln -s /Applications "$DEVHUB_STAGE/Applications"

hdiutil create \
  -volname "CodeReentry $DEVHUB_VERSION" \
  -srcfolder "$DEVHUB_STAGE" \
  -format UDZO \
  -ov \
  "$DEVHUB_DIST/$DEVHUB_BASENAME.dmg"

ditto -c -k --sequesterRsrc --keepParent \
  "$DEVHUB_APP" \
  "$DEVHUB_DIST/$DEVHUB_BASENAME.zip"

(
  cd "$DEVHUB_DIST"
  shasum -a 256 "$DEVHUB_BASENAME.dmg" "$DEVHUB_BASENAME.zip" \
    > "$DEVHUB_BASENAME.sha256"
)

echo "Local release created:"
echo "  $DEVHUB_DIST/$DEVHUB_BASENAME.dmg"
echo "  $DEVHUB_DIST/$DEVHUB_BASENAME.zip"
echo "This build is ad-hoc signed for local use and is not notarized for public distribution."
