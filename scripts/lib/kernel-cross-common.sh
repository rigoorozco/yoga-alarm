#!/bin/bash

# Provide kernel input/output hashes, architecture checks and archive validation.
# Sourced by build-kernel-cross.sh in x86/ARM64 Docker and by tests on the host.

kernel_input_manifest() {
    local entry filename
    {
        printf '%s\0' PKGBUILD
        if [[ -f linux-yoga.install ]]; then
            printf '%s\0' linux-yoga.install
        fi
        for entry in "${source[@]}"; do
            if [[ "$entry" == *::* ]]; then
                filename=${entry%%::*}
            else
                filename=${entry##*/}
            fi
            printf '%s\0' "$filename"
        done
    } | sort -zu | xargs -0 sha256sum
}

kernel_output_manifest() {
    local tree=$1
    sha256sum "$tree"/{.config,Module.symvers,System.map,vmlinux,version} \
        "$tree"/arch/arm64/boot/{Image,Image.gz}
    find "$tree" \
        -type f \( -name '*.ko' -o -name '*.dtb' -o -path '*/include/generated/*' \) \
        -print0 | sort -zu | xargs -0 -r sha256sum
}

kernel_require_arm64_elf() {
    local header
    header=$(LC_ALL=C readelf -h "$1") || return
    [[ "$header" == *'Machine:'*'AArch64'* ]] || {
        echo "ERROR: Expected ARM64 ELF: $1" >&2
        return 1
    }
}

kernel_verify_handoff() {
    local state=$1
    [[ -f "$state/complete" ]] || {
        echo 'ERROR: No completed kernel cross-build. Run the host launcher again.' >&2
        return 1
    }
    sha256sum --check --quiet "$state/inputs.sha256" || return
    sha256sum --check --quiet "$state/outputs.sha256"
}

kernel_extract_archives() {
    local incoming=$1 expected_version=$2 validation_dir=$3
    local archive metadata name version arch count=0
    local -A seen=()
    mkdir -p "$validation_dir"

    for archive in "$incoming"/*.pkg.tar.*; do
        [[ -f "$archive" && "$archive" != *.sig ]] || continue
        metadata=$(bsdtar -xOf "$archive" .PKGINFO) || return
        name=$(awk -F ' = ' '$1 == "pkgname" {print $2; exit}' <<< "$metadata")
        version=$(awk -F ' = ' '$1 == "pkgver" {print $2; exit}' <<< "$metadata")
        arch=$(awk -F ' = ' '$1 == "arch" {print $2; exit}' <<< "$metadata")
        case "$name" in
            linux-yoga|linux-yoga-headers) ;;
            *) echo "ERROR: Unexpected package: $name" >&2; return 1 ;;
        esac
        [[ "$version" == "$expected_version" && "$arch" == aarch64 && -z ${seen[$name]:-} ]] || {
            echo "ERROR: Unexpected kernel package identity: $name $version $arch" >&2
            return 1
        }
        seen[$name]=1
        mkdir -p "$validation_dir/$name" || return
        bsdtar -xf "$archive" -C "$validation_dir/$name" || return
        count=$((count + 1))
    done
    if [[ "$count" != 2 ]]; then
        echo 'ERROR: Expected kernel and headers archives.' >&2
        return 1
    fi
}

kernel_validate_boot_files() {
    local package_root=$1
    local image="$package_root/boot/Image"
    local board_dtb="$package_root/boot/dtbs/qcom/sdm850-lenovo-yoga-c630.dtb"

    # The arm64 Image header has the ARM\x64 magic at offset 0x38.
    python - "$image" <<'PYTHON' || return
import sys
with open(sys.argv[1], 'rb') as image:
    image.seek(0x38)
    assert image.read(4) == b'ARM\x64', 'Invalid ARM64 kernel image'
PYTHON
    gzip -cd "$image.gz" | cmp - "$image" || return
    dtc -q -I dtb -O dts -o /dev/null "$board_dtb"
}

kernel_validate_module_elf() {
    local module=$1 scratch_file=$2
    local elf_file=$module

    case "$module" in
        *.gz) gzip -cd "$module" > "$scratch_file" || return ;;
        *.xz) xz -cd "$module" > "$scratch_file" || return ;;
        *.zst) zstd -qd -c "$module" > "$scratch_file" || return ;;
    esac
    if [[ "$module" != *.ko ]]; then
        elf_file=$scratch_file
    fi
    kernel_require_arm64_elf "$elf_file"
}

kernel_validate_modules() {
    local modules_dir=$1 scratch_file=$2
    local module count=0

    while IFS= read -r -d '' module; do
        kernel_validate_module_elf "$module" "$scratch_file" || return
        count=$((count + 1))
    done < <(find "$modules_dir" -type f \
        \( -name '*.ko' -o -name '*.ko.gz' -o -name '*.ko.xz' -o -name '*.ko.zst' \) -print0)

    if (( count == 0 )); then
        echo 'ERROR: Kernel package has no modules.' >&2
        return 1
    fi
}

kernel_validate_headers() {
    local headers=$1 expected_release=$2
    local file

    [[ -f "$headers/Module.symvers" && -f "$headers/.config" ]] || return 1
    [[ $(<"$headers/version") == "$expected_release" ]] || return 1
    kernel_require_arm64_elf "$headers/vmlinux" || return

    while IFS= read -r -d '' file; do
        if readelf -h "$file" >/dev/null 2>&1; then
            kernel_require_arm64_elf "$file" || return
        fi
    done < <(find "$headers" -type f -perm /111 ! -name vmlinux -print0)

    for file in scripts/basic/fixdep scripts/mod/modpost; do
        kernel_require_arm64_elf "$headers/$file" || return
    done
}

kernel_validate_archives() (
    # Check extracted archives before they can be published to the repository.
    local incoming=$1 expected_version=$2 expected_release=$3 validation_dir=$4
    local package_root="$validation_dir/linux-yoga"
    local modules_dir="$package_root/usr/lib/modules/$expected_release"
    local headers="$validation_dir/linux-yoga-headers/usr/lib/modules/$expected_release/build"

    kernel_extract_archives "$incoming" "$expected_version" "$validation_dir" || return
    kernel_validate_headers "$headers" "$expected_release" || return
    kernel_validate_boot_files "$package_root" || return
    kernel_validate_modules "$modules_dir" "$validation_dir/module.ko" || return

    # The headers package owns build/; container workspace links must not be shipped.
    [[ ! -e "$modules_dir/build" && ! -L "$modules_dir/build" && ! -L "$modules_dir/source" ]]
)
