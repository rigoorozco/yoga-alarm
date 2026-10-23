#!/bin/bash

# Set up ARM64 emulation, build the Docker image, and launch package builds.
# Run on the host; invokes build-packages.sh inside Docker.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/scripts/package-common.sh"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    build_usage "$0"
    exit 0
fi
select_packages "$@"
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
docker build --platform "${PLATFORM}" -t "${IMAGE_NAME}" -f "${PROJECT_ROOT}/Dockerfile" "${PROJECT_ROOT}"

log "Running Docker build.."
docker run --rm -it \
    --privileged \
    --platform "${PLATFORM}" \
    -v "${PROJECT_ROOT}/scripts:/scripts:ro" \
    -v "${PROJECT_ROOT}/packages:/packages" \
    "${IMAGE_NAME}" \
    /scripts/build-packages.sh "${SELECTED_PACKAGES[@]}"

log "Build completed successfully!"
log "The following packages were created:"
find "${PROJECT_ROOT}/packages/repo" -maxdepth 1 -type f -name "*.pkg.tar.*" ! -name "*.sig"
