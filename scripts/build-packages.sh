#!/bin/bash

# Build selected ARM64 packages and update the local pacman repository.
# Used inside Docker, launched by run-docker-build.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/package-common.sh"
source "${SCRIPT_DIR}/repo-common.sh"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    build_usage "$0"
    exit 0
fi
select_packages "$@"

PKGS_DIR="${PKGS_DIR:-/packages}"
LOCAL_REPO_DIR="${PKGS_DIR}/repo"
PACMAN_CONF="${PACMAN_CONF:-/etc/pacman.conf}"

# Validate all explicitly requested packages before touching the container.
for pkgname in "${SELECTED_PACKAGES[@]}"; do
    [[ -f "${PKGS_DIR}/${pkgname}/PKGBUILD" ]] || {
        echo "ERROR: No PKGBUILD in ${PKGS_DIR}/${pkgname}" >&2
        exit 1
    }
done

export CARCH=aarch64
export PACKAGER="Rigo Orozco Díaz <rigo.orozco.d@gmail.com>"
export MAKEFLAGS="ARCH=arm64"

sudo chmod -R a+rwX "${PKGS_DIR}"
mkdir -p "${LOCAL_REPO_DIR}"

# Helper: add local repo to pacman config
ensure_local_repo_in_pacman() {
    local pacman_conf="$PACMAN_CONF"

    if ! grep -q "^\[${LOCAL_REPO_NAME}\]$" "${pacman_conf}"; then
        echo "Adding local repo to ${pacman_conf}..."
        sudo tee -a "${pacman_conf}" >/dev/null <<EOF

[${LOCAL_REPO_NAME}]
SigLevel = Optional TrustAll
Server = file://${LOCAL_REPO_DIR}
EOF
    fi
}

# Build in isolation so historical archives in the source directory are ignored.
build_and_publish() (
    local pkgname=$1 output
    echo "Building package: ${pkgname}..."
    cd "${PKGS_DIR}/${pkgname}"
    output=$(mktemp -d "${LOCAL_REPO_DIR}/.build-${pkgname}.XXXXXX")
    trap 'rm -rf -- "$output"' EXIT
    PKGDEST="$output" makepkg --cleanbuild --syncdeps --noconfirm --force --nosign
    update_repo "$LOCAL_REPO_DIR" "$output"
    sudo pacman -Sy --noconfirm --disable-sandbox
)

# The current local dependency graph has a single prerequisite: qrtr-git.
# Check installed dependencies first, then reusable archives with sufficient version.
have_qrtr() {
    local file metadata name version arch
    if pacman -T 'qrtr-git>=1.1' >/dev/null; then return 0; fi
    collect_archives "$LOCAL_REPO_DIR"
    for file in "${ARCHIVES[@]}"; do
        metadata=$(bsdtar -xOf "$file" .PKGINFO) || return
        name=$(awk -F ' = ' '$1 == "pkgname" { print $2; exit }' <<< "$metadata")
        [[ "$name" == qrtr-git ]] || continue
        version=$(awk -F ' = ' '$1 == "pkgver" { print $2; exit }' <<< "$metadata")
        arch=$(awk -F ' = ' '$1 == "arch" { print $2; exit }' <<< "$metadata")
        if [[ "$arch" == aarch64 || "$arch" == any ]] &&
           [[ -n "$version" ]] && (( $(vercmp "$version" 1.1) >= 0 )); then
            return 0
        fi
    done
    return 1
}

disable_legacy_community_repo() {
    local pacman_conf="$PACMAN_CONF"

    # Comment out [community] block if present
    if grep -q '^\[community\]$' "${pacman_conf}"; then
        echo "Disabling legacy [community] repo in ${pacman_conf}..."
        sudo sed -i '/^\[community\]/,/^Include = .*mirrorlist/ s/^/#/' "${pacman_conf}"
    fi
}

disable_legacy_community_repo
ensure_local_repo_in_pacman

needs_qrtr=0
for pkgname in "${SELECTED_PACKAGES[@]}"; do
    case "$pkgname" in tqftpserv-git|pd-mapper-git) needs_qrtr=1 ;; esac
done
if (( needs_qrtr )) && ! have_qrtr; then
    select_packages "${SELECTED_PACKAGES[@]}" qrtr-git
fi
for pkgname in "${SELECTED_PACKAGES[@]}"; do
    [[ -f "${PKGS_DIR}/${pkgname}/PKGBUILD" ]] || {
        echo "ERROR: No PKGBUILD in ${PKGS_DIR}/${pkgname}" >&2
        exit 1
    }
done

# Index existing packages before resolving dependencies in the fresh container.
collect_archives "$LOCAL_REPO_DIR"
if (( ${#ARCHIVES[@]} )); then update_repo "$LOCAL_REPO_DIR"; fi
sudo pacman -Syu --noconfirm --disable-sandbox

for pkgname in "${SELECTED_PACKAGES[@]}"; do
    build_and_publish "$pkgname"
done

echo "All done. Local repo available at: ${LOCAL_REPO_DIR}"
echo "Repo DB: ${LOCAL_REPO_DIR}/${LOCAL_REPO_NAME}.db.tar.gz"
