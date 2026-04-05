#!/bin/bash
# Usage: ./scripts/build-and-release.sh
# Requires: APPLE_ID, APP_SPECIFIC_PASSWORD, TEAM_ID, SIGNING_IDENTITY env vars
# or reads from .env file

set -euo pipefail

# --- Configuration (from env or .env file) ---
source .env 2>/dev/null || true
APP_NAME="SuperIsland"
SCHEME="${APP_NAME}"
BUILD_DIR="build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"
DMG_STAGING_DIR="${BUILD_DIR}/dmg-root"
ENTITLEMENTS="SuperIsland/SuperIsland.entitlements"

# Required env vars
: "${APPLE_ID:?Set APPLE_ID in .env}"
: "${APP_SPECIFIC_PASSWORD:?Set APP_SPECIFIC_PASSWORD in .env}"
: "${TEAM_ID:?Set TEAM_ID in .env}"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY in .env (e.g., 'Developer ID Application: Your Name (TEAMID)')}"

echo "==> Cleaning..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Archiving..."
xcodebuild archive \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -archivePath "${ARCHIVE_PATH}" \
  -destination "generic/platform=macOS" \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  ENABLE_HARDENED_RUNTIME=YES

echo "==> Exporting archive..."
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportOptionsPlist exportOptions.plist \
  -exportPath "${BUILD_DIR}"

echo "==> Verifying signature from export..."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

echo "==> Preparing DMG contents..."
mkdir -p "${DMG_STAGING_DIR}"
cp -R "${APP_PATH}" "${DMG_STAGING_DIR}/"
ln -s /Applications "${DMG_STAGING_DIR}/Applications"

echo "==> Creating DMG..."
hdiutil create -volname "${APP_NAME}" \
  -srcfolder "${DMG_STAGING_DIR}" \
  -ov -format UDZO \
  "${DMG_PATH}"

echo "==> Signing DMG..."
codesign --sign "${SIGNING_IDENTITY}" "${DMG_PATH}"

echo "==> Notarizing..."
xcrun notarytool submit "${DMG_PATH}" \
  --apple-id "${APPLE_ID}" \
  --password "${APP_SPECIFIC_PASSWORD}" \
  --team-id "${TEAM_ID}" \
  --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "${DMG_PATH}"

echo "==> Verifying notarization..."
xcrun stapler validate "${DMG_PATH}"
spctl --assess --type open --context context:primary-signature --verbose "${DMG_PATH}"

echo ""
echo "SUCCESS: ${DMG_PATH} is signed, notarized, and ready for distribution!"
echo "   File: $(du -h "${DMG_PATH}" | cut -f1) -- ${DMG_PATH}"
echo "   Open the mounted DMG, then drag ${APP_NAME}.app into Applications."
