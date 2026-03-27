#!/bin/bash
# Usage: ./scripts/build-dmg.sh
# Creates a local (unsigned) install-style DMG in build/ for development/testing.

set -euo pipefail

APP_NAME="DynamicIsland"
SCHEME="${APP_NAME}"
BUILD_DIR="build"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"
DMG_STAGING_DIR="${BUILD_DIR}/dmg-root"

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
  -destination "platform=macOS,arch=arm64" \
  ONLY_ACTIVE_ARCH=NO

echo "==> Copying app bundle..."
BUILT_APP=$(find "${DERIVED_DATA}" -name "${APP_NAME}.app" -type d | head -1)
if [ -z "${BUILT_APP}" ]; then
  echo "ERROR: Could not find built ${APP_NAME}.app"
  exit 1
fi
cp -R "${BUILT_APP}" "${APP_PATH}"

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
