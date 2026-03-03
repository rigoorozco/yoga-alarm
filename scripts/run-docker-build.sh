#!/bin/bash

# This script is meant to be run on the host machine

set -euo pipefail

PROJECT_ROOT=$(git rev-parse --show-toplevel)
IMAGE_NAME="${IMAGE_NAME:-archlinuxarm-build}"
PLATFORM="${PLATFORM:-linux/arm64}"
BASE_IMAGE_TEST="${BASE_IMAGE_TEST:-agners/archlinuxarm:latest}"

log() {
  echo "==> $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

require_cmd docker

log "Installing/registering binfmt for ARM64 on host (requires privileged Docker)..."
docker run --privileged --rm tonistiigi/binfmt --install arm64

log "Verifying Docker multi-arch execution (${PLATFORM})..."
ARCH_OUT="$(docker run --rm --platform "${PLATFORM}" "${BASE_IMAGE_TEST}" uname -m | tr -d '\r')"
echo "Container reported architecture: ${ARCH_OUT}"

case "${ARCH_OUT}" in
  aarch64|arm64)
    log "Multi-arch emulation looks good."
    ;;
  *)
    echo "ERROR: Expected ARM64 architecture (aarch64/arm64), got: ${ARCH_OUT}" >&2
    exit 1
    ;;
esac

log "Building ARM64 Arch Linux image: ${IMAGE_NAME}"
docker build --platform "${PLATFORM}" -t "${IMAGE_NAME}" -f Dockerfile .

log "Running Docker build.."
docker run --rm -it \
    --privileged \
    --platform "${PLATFORM}" \
    -v $(pwd)/scripts:/scripts \
    -v $(pwd)/packages:/packages \
    "${IMAGE_NAME}" \
    /scripts/build-packages.sh

log "Build competed successfully!"
log "The following packages were created:"
find ${PROJECT_ROOT}/packages/repo -name "*.pkg.tar.xz"
