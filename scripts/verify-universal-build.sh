#!/bin/bash
# Usage: ./scripts/verify-universal-build.sh path/to/SuperIsland.app [--skip-signature] [--skip-gatekeeper]

set -euo pipefail

APP_PATH=""
SKIP_SIGNATURE=0
SKIP_GATEKEEPER=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-signature)
      SKIP_SIGNATURE=1
      SKIP_GATEKEEPER=1
      ;;
    --skip-gatekeeper)
      SKIP_GATEKEEPER=1
      ;;
    -h|--help)
      echo "Usage: $0 path/to/SuperIsland.app [--skip-signature] [--skip-gatekeeper]"
      exit 0
      ;;
    *)
      if [ -z "${APP_PATH}" ]; then
        APP_PATH="$1"
      else
        echo "ERROR: unexpected argument: $1"
        exit 1
      fi
      ;;
  esac
  shift
done

if [ -z "${APP_PATH}" ]; then
  echo "ERROR: missing app path"
  echo "Usage: $0 path/to/SuperIsland.app [--skip-signature] [--skip-gatekeeper]"
  exit 1
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1"
    exit 1
  fi
}

for command_name in lipo codesign spctl; do
  require_command "${command_name}"
done

if [ ! -d "${APP_PATH}" ]; then
  echo "ERROR: app bundle not found: ${APP_PATH}"
  exit 1
fi

APP_BINARY="${APP_PATH}/Contents/MacOS/SuperIsland"
NODE_BINARY="${APP_PATH}/Contents/Resources/node"

check_universal_binary() {
  local binary_path="$1"
  local label="$2"

  if [ ! -f "${binary_path}" ]; then
    echo "ERROR: ${label} binary not found: ${binary_path}"
    exit 1
  fi

  local info
  info="$(lipo -info "${binary_path}")"
  echo "${info}"

  case "${info}" in
    *arm64*x86_64*|*x86_64*arm64*)
      ;;
    *)
      echo "ERROR: ${label} is not universal arm64 + x86_64"
      exit 1
      ;;
  esac
}

check_universal_binary "${APP_BINARY}" "SuperIsland"

if [ -f "${NODE_BINARY}" ]; then
  check_universal_binary "${NODE_BINARY}" "Bundled node"
fi

if [ "${SKIP_SIGNATURE}" = "0" ]; then
  codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
else
  echo "Skipping codesign verification"
fi

if [ "${SKIP_GATEKEEPER}" = "0" ]; then
  spctl --assess --type execute --verbose "${APP_PATH}"
else
  echo "Skipping Gatekeeper assessment"
fi

echo "Universal build verification passed: ${APP_PATH}"
