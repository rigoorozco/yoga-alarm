#!/bin/bash

# Rebuild the pacman repository databases from existing package archives.
# Run on the host; executes repo-common.sh helpers inside Docker.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_DIR="${REPO_DIR:-${PROJECT_ROOT}/packages/repo}"
IMAGE_NAME="${IMAGE_NAME:-archlinuxarm-build}"
PLATFORM="${PLATFORM:-linux/arm64}"

if (( $# > 0 )); then
    echo "Usage: $0" >&2
    echo "Environment: REPO_DIR, IMAGE_NAME, PLATFORM" >&2
    exit 1
fi

command -v docker >/dev/null 2>&1 || {
    echo "ERROR: docker is required." >&2
    exit 1
}
[[ -d "${REPO_DIR}" ]] || {
    echo "ERROR: Repository directory not found: ${REPO_DIR}" >&2
    exit 1
}
REPO_DIR="$(cd "${REPO_DIR}" && pwd)"

docker run --rm \
    --platform "${PLATFORM}" \
    --user "$(id -u):$(id -g)" \
    --mount "type=bind,source=${REPO_DIR},target=/repo" \
    --mount "type=bind,source=${PROJECT_ROOT}/scripts,target=/scripts,readonly" \
    --workdir /repo \
    --entrypoint /bin/bash \
    "${IMAGE_NAME}" -euo pipefail -c '
        source /scripts/lib/repo-common.sh
        update_repo /repo
    '
