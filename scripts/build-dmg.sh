#!/bin/bash
# Usage: ./scripts/build-dmg.sh [--dry-run]
# Creates a local (unsigned) install-style DMG in build/ for development/testing.

set -euo pipefail

DRY_RUN=0
APP_NAME="SuperIsland"
SCHEME="${APP_NAME}"
BUILD_DIR="build"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"
DMG_STAGING_DIR="${BUILD_DIR}/dmg-root"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      echo "Usage: $0 [--dry-run]"
      exit 0
      ;;
    *)
      echo "ERROR: unexpected argument: $1"
      exit 1
      ;;
  esac
  shift
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1"
    exit 1
  fi
}

for command_name in xcodegen xcodebuild hdiutil lipo security codesign; do
  require_command "${command_name}"
done

if [ "${DRY_RUN}" = "1" ]; then
  echo "Dry run: local DMG build prerequisites are available"
  ./scripts/bundle-node-runtime.sh "${APP_PATH}" --dry-run
  echo "Dry run: would build a universal Release app and create ${DMG_PATH}"
  exit 0
fi

echo "==> Cleaning build directory..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Building..."
xcodebuild build \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA}" \
  -destination "generic/platform=macOS" \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS="arm64 x86_64"

echo "==> Copying app bundle..."
BUILT_APP=$(find "${DERIVED_DATA}" -name "${APP_NAME}.app" -type d | head -1)
if [ -z "${BUILT_APP}" ]; then
  echo "ERROR: Could not find built ${APP_NAME}.app"
  exit 1
fi
cp -R "${BUILT_APP}" "${APP_PATH}"

echo "==> Bundling Node.js runtime..."
./scripts/bundle-node-runtime.sh "${APP_PATH}"
echo "   Bundled node ($(du -sh "${APP_PATH}/Contents/Resources/node" | cut -f1))"

echo "==> Code signing for local testing..."
# An unsigned app can't register with TCC (Calendar, Location, etc. won't appear in System Settings).
# Sign with any available development or Developer ID certificate if one exists.
CERT=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -E "Apple Development|Developer ID Application" \
  | head -1 \
  | awk -F'"' '{print $2}')
if [ -n "${CERT}" ]; then
  codesign --deep --force --sign "${CERT}" \
    --entitlements "SuperIsland/SuperIsland.entitlements" \
    "${APP_PATH}"
  echo "   Signed with: ${CERT}"
else
  echo "   Warning: no signing certificate found — TCC permissions (Calendar, etc.) won't register."
fi

echo "==> Verifying universal binaries..."
./scripts/verify-universal-build.sh "${APP_PATH}" --skip-signature

echo "==> Preparing DMG contents..."
mkdir -p "${DMG_STAGING_DIR}"
cp -R "${APP_PATH}" "${DMG_STAGING_DIR}/"
ln -s /Applications "${DMG_STAGING_DIR}/Applications"

echo "==> Creating DMG..."
rm -f "${DMG_PATH}"
hdiutil create -volname "${APP_NAME}" \
  -srcfolder "${DMG_STAGING_DIR}" \
  -ov -format UDZO \
  "${DMG_PATH}"

echo ""
echo "SUCCESS: ${DMG_PATH}"
echo "   Size: $(du -h "${DMG_PATH}" | cut -f1)"
echo "   Open the mounted DMG, then drag ${APP_NAME}.app into Applications."

if [ "${OPEN_DMG_ON_SUCCESS:-1}" = "1" ]; then
  echo "==> Opening DMG..."
  open "${DMG_PATH}" || true
fi
