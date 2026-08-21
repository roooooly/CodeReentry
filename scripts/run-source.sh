#!/bin/sh
set -eu

devhub_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
devhub_derived_data=${DEVHUB_DERIVED_DATA_PATH:-"$devhub_repo_root/build/SourceDerivedData"}
devhub_configuration=Release
devhub_build_only=false
devhub_demo=false
devhub_install=false

usage() {
  cat <<'EOF'
Usage: ./scripts/run-source.sh [--build-only] [--demo] [--install]

Build a verified, ad-hoc-signed copy of CodeReentry directly from this checkout.
By default the script launches the resulting app. Use --build-only in CI or
when you only want to verify the source-build path. Use --demo to launch an
isolated, in-memory workspace containing synthetic projects and sessions; demo
mode does not read local sessions or launch external developer tools. Use
--install to place the verified local build in ~/Applications before launch.

Environment:
  DEVHUB_DERIVED_DATA_PATH  Override the ignored build directory.
  CODEREENTRY_INSTALL_DIRECTORY  Override the user-level install directory.
  CODEREENTRY_BUILD_ARCH  Override the target architecture (arm64 or x86_64).
EOF
}

for devhub_arg in "$@"; do
  case "$devhub_arg" in
    --build-only) devhub_build_only=true ;;
    --demo) devhub_demo=true ;;
    --install) devhub_install=true ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

command -v xcodebuild >/dev/null 2>&1 || {
  echo "error: Xcode is required to build CodeReentry" >&2
  exit 1
}

test -f "$devhub_repo_root/DevHub.xcodeproj/project.pbxproj" || {
  echo "error: committed DevHub.xcodeproj is missing" >&2
  exit 1
}

devhub_host_arch=$(uname -m)
devhub_arch=${CODEREENTRY_BUILD_ARCH:-$devhub_host_arch}
case "$devhub_arch" in
  arm64|x86_64) ;;
  *)
    echo "error: unsupported target architecture: $devhub_arch" >&2
    exit 1
    ;;
esac

devhub_app="$devhub_derived_data/Build/Products/$devhub_configuration/CodeReentry.app"

echo "Building CodeReentry from the committed Xcode project (target: $devhub_arch; host: $devhub_host_arch)…"
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
if [ "$devhub_install" = true ]; then
  devhub_install_directory=${CODEREENTRY_INSTALL_DIRECTORY:-"${HOME:?}/Applications"}
  "$devhub_repo_root/scripts/install-source-app.sh" \
    "$devhub_app" "$devhub_install_directory"
  devhub_app="$devhub_install_directory/CodeReentry.app"
fi
if [ "$devhub_build_only" = true ]; then
  exit 0
fi

if [ "$devhub_demo" = true ]; then
  echo "Launching isolated CodeReentry demo with synthetic, disposable data."
  open -n "$devhub_app" --args --demo
else
  echo "Launching CodeReentry. It will not scan projects or sessions until you choose to do so."
  open -n "$devhub_app"
fi
