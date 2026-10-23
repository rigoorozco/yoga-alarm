#!/bin/bash

# Define package selection, dependency order, and build usage helpers.
# Sourced on the host by run-docker-build.sh and inside Docker by build-packages.sh.

BUILD_ORDER=(
    qmic-git
    qrtr-git
    tqftpserv-git
    pd-mapper-git
    firmware-lenovo-yoga-c630
    alsa-ucm-conf-yoga-c630
    edk2-shell-aa64
    linux-yoga
)

build_usage() {
    printf 'Usage: %s [PACKAGE ...]\n\nNo arguments builds all packages in dependency order.\nPackages:\n' "$1"
    printf '  %s\n' "${BUILD_ORDER[@]}"
}

select_packages() {
    local name candidate found
    SELECTED_PACKAGES=()
    if (( $# == 0 )); then
        SELECTED_PACKAGES=("${BUILD_ORDER[@]}")
        return
    fi
    for name in "$@"; do
        found=0
        for candidate in "${BUILD_ORDER[@]}"; do
            if [[ "$name" == "$candidate" ]]; then found=1; break; fi
        done
        if (( ! found )); then
            printf 'ERROR: Unknown package: %s\n' "$name" >&2
            return 1
        fi
    done
    for candidate in "${BUILD_ORDER[@]}"; do
        for name in "$@"; do
            if [[ "$candidate" == "$name" ]]; then
                SELECTED_PACKAGES+=("$candidate")
                break
            fi
        done
    done
}
