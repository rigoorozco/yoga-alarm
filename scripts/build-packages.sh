#!/bin/bash
set -euo pipefail

# This script is meant to be run inside Docker

PKGS_DIR=/packages
LOCAL_REPO_DIR="${PKGS_DIR}/repo"
LOCAL_REPO_NAME="localrepo"

echo "Running Docker build script.."

export CARCH=aarch64
export PACKAGER="Rigo Orozco Díaz <rigo.orozco.d@gmail.com>"
export GPGKEY="0x0123456789abcdef"
export MAKEFLAGS="ARCH=arm64"

sudo chmod -R 777 "${PKGS_DIR}"
mkdir -p "${LOCAL_REPO_DIR}"

# Helper: rebuild local repo database from all built packages
refresh_repo_db() {
    shopt -s nullglob
    local pkgs=( "${LOCAL_REPO_DIR}"/*.pkg.tar.* )
    if (( ${#pkgs[@]} > 0 )); then
        rm -f "${LOCAL_REPO_DIR}/${LOCAL_REPO_NAME}.db"* \
              "${LOCAL_REPO_DIR}/${LOCAL_REPO_NAME}.files"*
        repo-add "${LOCAL_REPO_DIR}/${LOCAL_REPO_NAME}.db.tar.gz" "${pkgs[@]}"
    fi
    shopt -u nullglob
}

# Helper: add local repo to pacman config
ensure_local_repo_in_pacman() {
    local pacman_conf="/etc/pacman.conf"

    if ! grep -q "^\[${LOCAL_REPO_NAME}\]$" "${pacman_conf}"; then
        echo "Adding local repo to ${pacman_conf}..."
        sudo tee -a "${pacman_conf}" >/dev/null <<EOF

[${LOCAL_REPO_NAME}]
SigLevel = Optional TrustAll
Server = file://${LOCAL_REPO_DIR}
EOF
    fi
}

# Helper: build one package dir and publish resulting package(s) into local repo
build_and_publish() {
    local pkgname="$1"
    local pkgdir="${PKGS_DIR}/${pkgname}"

    if [[ ! -d "${pkgdir}" ]]; then
        echo "ERROR: Package directory not found: ${pkgdir}" >&2
        exit 1
    fi
    if [[ ! -f "${pkgdir}/PKGBUILD" ]]; then
        echo "ERROR: No PKGBUILD in: ${pkgdir}" >&2
        exit 1
    fi

    echo "Building package: ${pkgname} (${pkgdir})..."
    cd "${pkgdir}"

    # Build and install missing deps via pacman
    makepkg -s --nodeps --noconfirm -f

    # Copy binary package archives into local repo (skip sig/src packages)
    shopt -s nullglob
    local built_pkgs=( ./*.pkg.tar.* )
    for f in "${built_pkgs[@]}"; do
        case "${f}" in
            *.sig|*.src.tar.*) continue ;;
        esac
        cp -f "${f}" "${LOCAL_REPO_DIR}/"
    done
    shopt -u nullglob

    refresh_repo_db
}

disable_legacy_community_repo() {
    local pacman_conf="/etc/pacman.conf"

    # Comment out [community] block if present
    if grep -q '^\[community\]$' "${pacman_conf}"; then
        echo "Disabling legacy [community] repo in ${pacman_conf}..."
        sudo sed -i '/^\[community\]/,/^Include = .*mirrorlist/ s/^/#/' "${pacman_conf}"
    fi
}

disable_legacy_community_repo
ensure_local_repo_in_pacman

# Explicit build order
build_and_publish "qmic-git"
sudo pacman -Sy --noconfirm --disable-sandbox
sudo pacman -Sy qrtr --noconfirm --disable-sandbox
build_and_publish "qmic-git"
build_and_publish "tqftpserv-git"
build_and_publish "pd-mapper-git"
build_and_publish "linux-yoga"

echo "All done. Local repo available at: ${LOCAL_REPO_DIR}"
echo "Repo DB: ${LOCAL_REPO_DIR}/${LOCAL_REPO_NAME}.db.tar.gz"
