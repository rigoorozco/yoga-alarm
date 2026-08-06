#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${REPO_DIR:-${PROJECT_ROOT}/packages/repo}"
GPG_BIN="${GPG_BIN:-gpg}"
SIGNING_KEY="${SIGNING_KEY:-}"
FORCE=0
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--repo-dir DIR] [--key KEYID] [--force] [--dry-run]

Sign existing pacman package archives in a local repository.

Options:
  --repo-dir DIR  Repository directory. Defaults to packages/repo.
  --key KEYID     GPG signing key to pass to gpg --local-user.
                  Can also be set with SIGNING_KEY.
  --force         Replace existing .sig files.
  --dry-run       Print the signatures that would be created.
  -h, --help      Show this help.

The script only creates detached package signatures. It does not build
packages and does not regenerate repository database files.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --repo-dir)
      [[ $# -ge 2 ]] || die "--repo-dir requires a value"
      REPO_DIR="$2"
      shift 2
      ;;
    --key)
      [[ $# -ge 2 ]] || die "--key requires a value"
      SIGNING_KEY="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -d "${REPO_DIR}" ]] || die "repo directory not found: ${REPO_DIR}"

shopt -s nullglob
packages=( "${REPO_DIR}"/*.pkg.tar.* )
shopt -u nullglob

to_sign=()
for pkg in "${packages[@]}"; do
  case "${pkg}" in
    *.sig|*.src.tar.*)
      continue
      ;;
  esac

  sig="${pkg}.sig"
  if [[ -f "${sig}" && "${FORCE}" -eq 0 ]]; then
    continue
  fi
  to_sign+=( "${pkg}" )
done

if (( ${#to_sign[@]} == 0 )); then
  echo "No unsigned package archives found in ${REPO_DIR}."
  exit 0
fi

for pkg in "${to_sign[@]}"; do
  sig="${pkg}.sig"
  echo "Signing ${pkg##*/}"

  if (( DRY_RUN )); then
    continue
  fi

  gpg_args=( --detach-sign --use-agent --output "${sig}" )
  if (( FORCE )); then
    gpg_args+=( --yes )
  fi
  if [[ -n "${SIGNING_KEY}" ]]; then
    gpg_args+=( --local-user "${SIGNING_KEY}" )
  fi
  gpg_args+=( "${pkg}" )

  "${GPG_BIN}" "${gpg_args[@]}"
done
