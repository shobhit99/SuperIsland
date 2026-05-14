#!/bin/bash
# Usage: ./scripts/build-and-release.sh [--dry-run]
# Requires: APPLE_ID, APP_SPECIFIC_PASSWORD, TEAM_ID, SIGNING_IDENTITY env vars
# or reads from .env file

set -euo pipefail

# --- Configuration (from env or .env file) ---
if [ -f .env ]; then
  source .env
fi
DRY_RUN=0
APP_NAME="SuperIsland"
SCHEME="${APP_NAME}"
BUILD_DIR="build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"
DMG_STAGING_DIR="${BUILD_DIR}/dmg-root"
ENTITLEMENTS="SuperIsland/SuperIsland.entitlements"

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

require_env() {
  local name="$1"
  local help="$2"
  if [ -z "${!name:-}" ]; then
    echo "ERROR: missing ${name}. ${help}"
    exit 1
  fi
}

for command_name in xcodegen xcodebuild curl tar lipo codesign hdiutil xcrun spctl; do
  require_command "${command_name}"
done

require_env "APPLE_ID" "Set APPLE_ID in .env."
require_env "APP_SPECIFIC_PASSWORD" "Set APP_SPECIFIC_PASSWORD in .env."
require_env "TEAM_ID" "Set TEAM_ID in .env."
require_env "SIGNING_IDENTITY" "Set SIGNING_IDENTITY in .env, for example: Developer ID Application: Your Name (TEAMID)."

if [ "${DRY_RUN}" = "1" ]; then
  echo "Dry run: release prerequisites and signing environment are available"
  ./scripts/bundle-node-runtime.sh "${APP_PATH}" --dry-run
  echo "Dry run: would archive a universal Release app, sign it, create ${DMG_PATH}, notarize it, and staple the ticket"
  exit 0
fi

echo "==> Cleaning..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Archiving..."
# Note: Do NOT set BUILD_LIBRARY_FOR_DISTRIBUTION=YES. That flag is for
# frameworks shipped as precompiled binaries; forcing it on makes every
# SwiftPM dependency emit + verify a .swiftinterface, which fails on some
# packages (e.g. Aptabase) and isn't useful for an app bundle.
# SWIFT_VERIFY_EMITTED_MODULE_INTERFACE=NO kept as a safety net.
xcodebuild archive \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -archivePath "${ARCHIVE_PATH}" \
  -destination "generic/platform=macOS" \
  SKIP_INSTALL=NO \
  SWIFT_VERIFY_EMITTED_MODULE_INTERFACE=NO \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS="arm64 x86_64" \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  ENABLE_HARDENED_RUNTIME=YES

echo "==> Extracting app from archive..."
# Skip `xcodebuild -exportArchive`: its IDEDistributionMethodManager is
# flaky on Xcode 16 for Developer ID, and we re-sign the whole bundle
# a few steps below anyway (after injecting the bundled node binary),
# so whatever signature the export step would have applied is discarded.
# Copying the .app directly out of the archive's Products is reliable.
APP_IN_ARCHIVE="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
if [ ! -d "${APP_IN_ARCHIVE}" ]; then
  echo "ERROR: ${APP_IN_ARCHIVE} not found after archive"
  exit 1
fi
rm -rf "${APP_PATH}"
cp -R "${APP_IN_ARCHIVE}" "${APP_PATH}"

echo "==> Bundling Node.js runtime..."
./scripts/bundle-node-runtime.sh "${APP_PATH}"
echo "   Bundled node ($(du -sh "${APP_PATH}/Contents/Resources/node" | cut -f1))"

echo "==> Re-signing app (required after injecting node binary)..."
# Sign the bundled node binary with JIT entitlements (V8 requires executable memory)
NODE_ENTITLEMENTS="SuperIsland/node.entitlements"
codesign --sign "${SIGNING_IDENTITY}" --force --options runtime \
  --entitlements "${NODE_ENTITLEMENTS}" \
  "${APP_PATH}/Contents/Resources/node"
# Re-sign the entire app bundle
codesign --sign "${SIGNING_IDENTITY}" --force --deep --options runtime \
  --entitlements "${ENTITLEMENTS}" \
  "${APP_PATH}"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
echo "==> Verifying universal binaries..."
./scripts/verify-universal-build.sh "${APP_PATH}" --skip-gatekeeper

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
echo "SUCCESS: ${DMG_PATH} is signed, notarized, and ready to ship!"
echo "   Size: $(du -h "${DMG_PATH}" | cut -f1) -- ${DMG_PATH}"
