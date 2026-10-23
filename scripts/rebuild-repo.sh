#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
    --workdir /repo \
    --entrypoint /bin/bash \
    "${IMAGE_NAME}" -euo pipefail -c '
        shopt -s nullglob
        packages=()
        for file in *.pkg.tar.*; do
            [[ "$file" == *.sig ]] && continue
            packages+=("/repo/$file")
        done
        if (( ${#packages[@]} == 0 )); then
            echo "ERROR: No package archives found; database left unchanged." >&2
            exit 1
        fi

        # Build separately so a failed repo-add leaves the current database intact.
        staging=$(mktemp -d /repo/.rebuild-repo.XXXXXX)
        trap '\''rm -rf -- "$staging"'\'' EXIT
        repo-add "$staging/yoga-alarm.db.tar.gz" "${packages[@]}"

        rm -f yoga-alarm.db* yoga-alarm.files*
        mv "$staging"/yoga-alarm.* /repo/
        echo "Repository database rebuilt from ${#packages[@]} package archives."
    '
