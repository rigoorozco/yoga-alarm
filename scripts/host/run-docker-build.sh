#!/bin/bash

# Set up images and ARM64 emulation, then route package and kernel builds.
# Run on the host; invokes build-packages.sh and build-kernel-cross.sh inside Docker.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${PROJECT_ROOT}/scripts/lib/package-common.sh"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    build_usage "$0"
    exit 0
fi
select_packages "$@"
IMAGE_NAME="${IMAGE_NAME:-archlinuxarm-build}"
PLATFORM="${PLATFORM:-linux/arm64}"
BASE_IMAGE_TEST="${BASE_IMAGE_TEST:-agners/archlinuxarm:latest}"
CCACHE_VOLUME="${CCACHE_VOLUME:-yoga-alarm-ccache}"
CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-10G}"
CROSS_IMAGE_NAME="${CROSS_IMAGE_NAME:-archlinuxarm-kernel-cross}"
KERNEL_BUILD_MODE="${KERNEL_BUILD_MODE:-cross}"
case "$KERNEL_BUILD_MODE" in
    cross|emulated) ;;
    *) echo 'ERROR: KERNEL_BUILD_MODE must be cross or emulated.' >&2; exit 1 ;;
esac

KERNEL_SELECTED=0
ARM_PACKAGES=()
for package in "${SELECTED_PACKAGES[@]}"; do
    if [[ "$package" == linux-yoga ]]; then
        KERNEL_SELECTED=1
        [[ "$KERNEL_BUILD_MODE" == cross ]] && continue
    fi
    ARM_PACKAGES+=("$package")
done

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

if (( KERNEL_SELECTED )); then
    require_cmd flock
    # Also covers the emulated fallback, which shares the same source tree.
    exec 8>"${PROJECT_ROOT}/packages/linux-yoga/.kernel-build.lock"
    flock -n 8 || { echo 'ERROR: Another kernel build holds the workspace lock.' >&2; exit 1; }
    if [[ "$KERNEL_BUILD_MODE" == cross ]]; then
        DOCKER_ARCH=$(docker info --format '{{.Architecture}}')
        case "$DOCKER_ARCH" in
            x86_64|amd64) ;;
            *) echo 'ERROR: Kernel cross builds require x86 Docker. Use KERNEL_BUILD_MODE=emulated.' >&2; exit 1 ;;
        esac
    fi
fi

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

COMMON_RUN_ARGS=(--rm -it
    --mount "type=volume,source=${CCACHE_VOLUME},target=/usr/local/build/.cache/ccache"
    -e CCACHE_DIR=/usr/local/build/.cache/ccache
    -e "CCACHE_MAXSIZE=${CCACHE_MAXSIZE}"
    -v "${PROJECT_ROOT}/scripts:/scripts:ro"
    -v "${PROJECT_ROOT}/packages:/packages")

if (( ${#ARM_PACKAGES[@]} )); then
    log "Building packages in ARM64 Docker..."
    docker run "${COMMON_RUN_ARGS[@]}" --privileged --platform "${PLATFORM}" \
        "${IMAGE_NAME}" /scripts/docker/build-packages.sh "${ARM_PACKAGES[@]}"
fi

if (( KERNEL_SELECTED )) && [[ "$KERNEL_BUILD_MODE" == cross ]]; then
    log "Building x86 kernel cross-compilation image: ${CROSS_IMAGE_NAME}"
    docker build --platform linux/amd64 -t "${CROSS_IMAGE_NAME}" \
        -f "${PROJECT_ROOT}/Dockerfile.cross" "${PROJECT_ROOT}"
    log "Cross-compiling the kernel..."
    docker run "${COMMON_RUN_ARGS[@]}" --platform linux/amd64 \
        "${CROSS_IMAGE_NAME}" /bin/bash /scripts/docker/build-kernel-cross.sh compile
    log "Preparing ARM64 headers tools, packaging and validating..."
    docker run "${COMMON_RUN_ARGS[@]}" --privileged --platform "${PLATFORM}" \
        "${IMAGE_NAME}" /bin/bash /scripts/docker/build-kernel-cross.sh package
fi

log "Build completed successfully!"
log "The following packages were created:"
find "${PROJECT_ROOT}/packages/repo" -maxdepth 1 -type f -name "*.pkg.tar.*" ! -name "*.sig"
