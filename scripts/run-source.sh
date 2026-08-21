#!/bin/sh
set -eu

devhub_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
devhub_derived_data=${DEVHUB_DERIVED_DATA_PATH:-"$devhub_repo_root/build/SourceDerivedData"}
devhub_configuration=Release
devhub_build_only=false

usage() {
  cat <<'EOF'
Usage: ./scripts/run-source.sh [--build-only]

Build a verified, ad-hoc-signed copy of DevHub directly from this checkout.
By default the script launches the resulting app. Use --build-only in CI or
when you only want to verify the source-build path.

Environment:
  DEVHUB_DERIVED_DATA_PATH  Override the ignored build directory.
EOF
}

case "${1:-}" in
  "") ;;
  --build-only) devhub_build_only=true ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac

if [ "$#" -gt 1 ]; then
  usage >&2
  exit 64
fi

command -v xcodebuild >/dev/null 2>&1 || {
  echo "error: Xcode is required to build DevHub" >&2
  exit 1
}

test -f "$devhub_repo_root/DevHub.xcodeproj/project.pbxproj" || {
  echo "error: committed DevHub.xcodeproj is missing" >&2
  exit 1
}

devhub_arch=$(uname -m)
case "$devhub_arch" in
  arm64|x86_64) ;;
  *)
    echo "error: unsupported Mac architecture: $devhub_arch" >&2
    exit 1
    ;;
esac

devhub_app="$devhub_derived_data/Build/Products/$devhub_configuration/DevHub.app"

echo "Building DevHub from the committed Xcode project ($devhub_arch)…"
echo "The first build can take several minutes while Swift packages resolve."
xcodebuild \
  -quiet \
  -project "$devhub_repo_root/DevHub.xcodeproj" \
  -scheme DevHub \
  -configuration "$devhub_configuration" \
  -destination "platform=macOS,arch=$devhub_arch" \
  -derivedDataPath "$devhub_derived_data" \
  ARCHS="$devhub_arch" \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  CODE_SIGN_ENTITLEMENTS="$devhub_repo_root/DevHub.local-release.entitlements" \
  build

test -d "$devhub_app"
"$devhub_repo_root/scripts/verify-release.sh" "$devhub_app" "$devhub_arch"

echo "Source build ready: $devhub_app"
if [ "$devhub_build_only" = true ]; then
  exit 0
fi

echo "Launching DevHub. It will not scan projects or sessions until you choose to do so."
open -n "$devhub_app"
