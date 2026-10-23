#!/bin/bash

# Provide archive selection and pacman repository update helpers.
# Sourced inside Docker by build-packages.sh and the rebuild-repo.sh container command.
# Callers use set -euo pipefail.

LOCAL_REPO_NAME=yoga-alarm

# Return package paths without sidecar signatures, directories, or source archives.
collect_archives() {
    local dir=$1 file
    ARCHIVES=()
    for file in "$dir"/*.pkg.tar.*; do
        [[ -f "$file" ]] || continue
        case "$file" in *.sig|*.src.tar.*) continue ;; esac
        ARCHIVES+=("$file")
    done
}

# Read archive metadata rather than guessing names from hyphenated filenames.
package_identity() {
    local metadata name arch
    metadata=$(bsdtar -xOf "$1" .PKGINFO) || return
    name=$(awk -F ' = ' '$1 == "pkgname" { print $2; exit }' <<< "$metadata")
    arch=$(awk -F ' = ' '$1 == "arch" { print $2; exit }' <<< "$metadata")
    [[ -n "$name" && -n "$arch" ]] || {
        echo "ERROR: Missing package name or architecture in $1" >&2
        return 1
    }
    printf '%s:%s\n' "$name" "$arch"
}

# With no second argument, rebuild only. Otherwise publish archives from that
# directory, replacing all previous releases of the same name and architecture.
update_repo() (
    local repo=$1 incoming=${2:-} staging file identity
    local -a existing new retained obsolete
    local -A replacements=()
    mkdir -p "$repo"
    exec 9>"$repo/.repo.lock"
    flock -x 9
    collect_archives "$repo"
    existing=("${ARCHIVES[@]}")
    new=()
    if [[ -n "$incoming" ]]; then
        collect_archives "$incoming"
        new=("${ARCHIVES[@]}")
        if (( ${#new[@]} == 0 )); then
            echo 'ERROR: Build produced no package archives; repository left unchanged.' >&2
            exit 1
        fi
        for file in "${new[@]}"; do
            identity=$(package_identity "$file")
            replacements["$identity"]=1
        done
    fi
    retained=() obsolete=()
    for file in "${existing[@]}"; do
        if (( ${#new[@]} )); then
            identity=$(package_identity "$file")
            if [[ -n "${replacements[$identity]:-}" ]]; then
                obsolete+=("$file")
                continue
            fi
        fi
        retained+=("$file")
    done
    if (( ${#retained[@]} + ${#new[@]} == 0 )); then
        echo 'ERROR: No package archives found; database left unchanged.' >&2
        exit 1
    fi

    staging=$(mktemp -d "$repo/.rebuild-repo.XXXXXX")
    trap 'rm -rf -- "$staging"' EXIT
    # Prepare before modifying any published archive or database. repo-add reads
    # adjacent signatures itself; signatures must never be package arguments.
    repo-add --include-sigs "$staging/$LOCAL_REPO_NAME.db.tar.gz" "${retained[@]}" "${new[@]}"
    for file in "${new[@]}"; do
        cp -f -- "$file" "$repo/${file##*/}"
        rm -f -- "$repo/${file##*/}.sig"
        if [[ -f "$file.sig" ]]; then
            cp -f -- "$file.sig" "$repo/${file##*/}.sig"
        fi
    done
    rm -f -- "$repo/$LOCAL_REPO_NAME".db* "$repo/$LOCAL_REPO_NAME".files*
    mv -- "$staging/$LOCAL_REPO_NAME".* "$repo/"
    for file in "${obsolete[@]}"; do
        # An overwritten filename is now the new archive; keep it.
        local replaced=0 output
        for output in "${new[@]}"; do
            if [[ "${file##*/}" == "${output##*/}" ]]; then replaced=1; break; fi
        done
        if (( ! replaced )); then rm -f -- "$file" "$file.sig"; fi
    done
    printf 'Repository database rebuilt from %s package archives.\n' "$(( ${#retained[@]} + ${#new[@]} ))"
)
