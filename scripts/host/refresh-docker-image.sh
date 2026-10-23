#!/bin/bash

# Refresh the ARM64 package and x86 kernel cross-build images without cache.
# Run on the host; pulls base images and updates the tools used by run-docker-build.sh.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-archlinuxarm-build}"
PLATFORM="${PLATFORM:-linux/arm64}"
CROSS_IMAGE_NAME="${CROSS_IMAGE_NAME:-archlinuxarm-kernel-cross}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--arm64-only] [--help]

Pull the latest base image and rebuild all Docker layers to update build tools.
Refresh both ARM64 and x86 cross-build images, or only ARM64 with --arm64-only.
Environment: IMAGE_NAME, PLATFORM, CROSS_IMAGE_NAME (archlinuxarm-kernel-cross)
EOF
}

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    usage
    exit 0
fi
ARM64_ONLY=0
if [[ "${1:-}" == --arm64-only ]]; then
    ARM64_ONLY=1
    shift
fi
if (( $# > 0 )); then
    usage >&2
    exit 1
fi

command -v docker >/dev/null 2>&1 || {
    echo "ERROR: docker is required." >&2
    exit 1
}

if (( ! ARM64_ONLY )); then
    DOCKER_ARCH=$(docker info --format '{{.Architecture}}')
    case "$DOCKER_ARCH" in
        x86_64|amd64) ;;
        *) echo 'ERROR: Refreshing the cross image requires x86 Docker. Use --arm64-only.' >&2; exit 1 ;;
    esac
fi

echo "==> Installing/registering ARM64 emulation (requires privileged Docker)..."
docker run --privileged --rm tonistiigi/binfmt --install arm64

echo "==> Refreshing Docker build image: ${IMAGE_NAME}"
docker build --pull --no-cache \
    --platform "${PLATFORM}" \
    -t "${IMAGE_NAME}" \
    -f "${PROJECT_ROOT}/Dockerfile" \
    "${PROJECT_ROOT}"

if (( ! ARM64_ONLY )); then
    docker build --pull --no-cache --platform linux/amd64 \
        -t "${CROSS_IMAGE_NAME}" -f "${PROJECT_ROOT}/Dockerfile.cross" "${PROJECT_ROOT}"
fi

echo "==> Image refreshed. Run scripts/host/run-docker-build.sh to build packages."
