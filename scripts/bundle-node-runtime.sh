#!/bin/bash
# Usage: ./scripts/bundle-node-runtime.sh path/to/SuperIsland.app [--dry-run]

set -euo pipefail

APP_PATH=""
DRY_RUN=0
NODE_VERSION="${NODE_VERSION:-20.19.0}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      echo "Usage: $0 path/to/SuperIsland.app [--dry-run]"
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
  echo "Usage: $0 path/to/SuperIsland.app [--dry-run]"
  exit 1
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1"
    exit 1
  fi
}

for command_name in curl tar lipo mktemp; do
  require_command "${command_name}"
done

NODE_DEST="${APP_PATH}/Contents/Resources/node"

if [ "${DRY_RUN}" = "1" ]; then
  echo "Dry run: would download Node.js ${NODE_VERSION} for darwin-arm64 and darwin-x64"
  echo "Dry run: would create universal runtime at ${NODE_DEST}"
  exit 0
fi

if [ ! -d "${APP_PATH}/Contents/Resources" ]; then
  echo "ERROR: app resources directory not found: ${APP_PATH}/Contents/Resources"
  exit 1
fi

NODE_TMP="$(mktemp -d)"
cleanup() {
  rm -rf "${NODE_TMP}"
}
trap cleanup EXIT

nodes=()
for node_arch in arm64 x64; do
  arch_dir="${NODE_TMP}/${node_arch}"
  archive="${NODE_TMP}/node-${node_arch}.tar.gz"
  mkdir -p "${arch_dir}"

  echo "   Downloading node-v${NODE_VERSION}-darwin-${node_arch}..."
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-darwin-${node_arch}.tar.gz" \
    -o "${archive}"
  tar -xzf "${archive}" \
    -C "${arch_dir}" \
    --strip-components=2 \
    "node-v${NODE_VERSION}-darwin-${node_arch}/bin/node"
  nodes+=("${arch_dir}/node")
done

lipo -create "${nodes[@]}" -output "${NODE_DEST}"
chmod +x "${NODE_DEST}"
lipo -info "${NODE_DEST}"
