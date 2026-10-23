#!/bin/bash

# Run on the host to refresh the Docker image used by run-docker-build.sh.
# Pull the latest ARM64 base image and rebuild without cache to update its
# installed Arch Linux ARM packages and build tools.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-archlinuxarm-build}"
PLATFORM="${PLATFORM:-linux/arm64}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--help]

Pull the latest base image and rebuild all Docker layers to update build tools.
Environment: IMAGE_NAME (archlinuxarm-build), PLATFORM (linux/arm64)
EOF
}

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    usage
    exit 0
fi
if (( $# > 0 )); then
    usage >&2
    exit 1
fi

command -v docker >/dev/null 2>&1 || {
    echo "ERROR: docker is required." >&2
    exit 1
}

echo "==> Installing/registering ARM64 emulation (requires privileged Docker)..."
docker run --privileged --rm tonistiigi/binfmt --install arm64

echo "==> Refreshing Docker build image: ${IMAGE_NAME}"
docker build --pull --no-cache \
    --platform "${PLATFORM}" \
    -t "${IMAGE_NAME}" \
    -f "${PROJECT_ROOT}/Dockerfile" \
    "${PROJECT_ROOT}"

echo "==> Image refreshed. Run scripts/host/run-docker-build.sh to build packages."
