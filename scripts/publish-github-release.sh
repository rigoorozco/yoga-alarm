#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
REPO_DIR="${REPO_DIR:-${PROJECT_ROOT}/packages/repo}"
VERSION_TAG="${VERSION_TAG:-packages-$(date +%F)}"
LATEST_TAG="${LATEST_TAG:-packages-latest}"
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run]

Publish packages from packages/repo to GitHub releases.

Environment:
  GITHUB_REPOSITORY  owner/repo target. Defaults to git remote origin.
  REPO_DIR           package repository directory. Defaults to packages/repo.
  VERSION_TAG        dated release tag. Defaults to packages-YYYY-MM-DD.
  LATEST_TAG         moving release tag. Defaults to packages-latest.

The script creates/updates VERSION_TAG and replaces LATEST_TAG with the same
assets so pacman can use the stable packages-latest download URL.
EOF
}

log() {
  echo "==> $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

run() {
  if (( DRY_RUN )); then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

github_repository_from_origin() {
  local remote

  remote="$(git -C "${PROJECT_ROOT}" remote get-url origin)"
  case "${remote}" in
    git@github.com:*.git)
      remote="${remote#git@github.com:}"
      echo "${remote%.git}"
      ;;
    https://github.com/*.git)
      remote="${remote#https://github.com/}"
      echo "${remote%.git}"
      ;;
    https://github.com/*)
      echo "${remote#https://github.com/}"
      ;;
    *)
      die "cannot infer GITHUB_REPOSITORY from origin: ${remote}"
      ;;
  esac
}

collect_assets() {
  shopt -s nullglob
  ASSETS=(
    "${REPO_DIR}/localrepo.db"
    "${REPO_DIR}/localrepo.db.tar.gz"
    "${REPO_DIR}/localrepo.files"
    "${REPO_DIR}/localrepo.files.tar.gz"
    "${REPO_DIR}"/*.pkg.tar.*
  )
  shopt -u nullglob
}

validate_assets() {
  [[ -d "${REPO_DIR}" ]] || die "repo directory not found: ${REPO_DIR}"
  [[ -f "${REPO_DIR}/localrepo.db" ]] || die "missing repo database alias: ${REPO_DIR}/localrepo.db"
  [[ -f "${REPO_DIR}/localrepo.db.tar.gz" ]] || die "missing repo database: ${REPO_DIR}/localrepo.db.tar.gz"
  [[ -f "${REPO_DIR}/localrepo.files" ]] || die "missing repo files database alias: ${REPO_DIR}/localrepo.files"
  [[ -f "${REPO_DIR}/localrepo.files.tar.gz" ]] || die "missing repo files database: ${REPO_DIR}/localrepo.files.tar.gz"

  collect_assets
  (( ${#ASSETS[@]} > 4 )) || die "no package archives found in ${REPO_DIR}"

  for asset in "${ASSETS[@]}"; do
    [[ -f "${asset}" ]] || die "asset is not a file: ${asset}"
  done
}

release_exists() {
  local tag="$1"

  if (( DRY_RUN )); then
    return 1
  fi

  gh release view "${tag}" --repo "${GITHUB_REPOSITORY}" >/dev/null 2>&1
}

create_or_update_versioned_release() {
  if release_exists "${VERSION_TAG}"; then
    log "Updating existing release: ${VERSION_TAG}"
    run gh release upload "${VERSION_TAG}" "${ASSETS[@]}" \
      --repo "${GITHUB_REPOSITORY}" \
      --clobber
  else
    log "Creating release: ${VERSION_TAG}"
    run gh release create "${VERSION_TAG}" "${ASSETS[@]}" \
      --repo "${GITHUB_REPOSITORY}" \
      --title "${VERSION_TAG}" \
      --notes "Arch Linux ARM package repository snapshot."
  fi
}

replace_latest_release() {
  if release_exists "${LATEST_TAG}"; then
    log "Deleting existing moving release: ${LATEST_TAG}"
    run gh release delete "${LATEST_TAG}" \
      --repo "${GITHUB_REPOSITORY}" \
      --cleanup-tag \
      --yes
  fi

  log "Creating moving release: ${LATEST_TAG}"
  run gh release create "${LATEST_TAG}" "${ASSETS[@]}" \
    --repo "${GITHUB_REPOSITORY}" \
    --title "${LATEST_TAG}" \
    --notes "Latest Arch Linux ARM package repository. Mirrors ${VERSION_TAG}."
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

require_cmd git
if (( ! DRY_RUN )); then
  require_cmd gh
fi

GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$(github_repository_from_origin)}"

validate_assets

log "Publishing ${#ASSETS[@]} assets from ${REPO_DIR}"
log "Target repository: ${GITHUB_REPOSITORY}"
log "Versioned release: ${VERSION_TAG}"
log "Moving release: ${LATEST_TAG}"

if (( ! DRY_RUN )); then
  gh auth status >/dev/null
fi

create_or_update_versioned_release
replace_latest_release

log "Done."
log "Pacman Server URL: https://github.com/${GITHUB_REPOSITORY}/releases/download/${LATEST_TAG}"
