#!/bin/bash

# Cross-compile the kernel in x86 Docker, or package and validate it in ARM64 Docker.
# Called by run-docker-build.sh with compile or package while it holds the workspace lock.

set -euo pipefail
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/kernel-cross-common.sh"
source "$SCRIPT_DIR/../lib/repo-common.sh"

case "${1:-}" in
    compile|package) STAGE=$1 ;;
    *) echo "Usage: $0 compile|package" >&2; exit 1 ;;
esac

cd "${PKGS_DIR:-/packages}/linux-yoga"
PACKAGE_DIR=$PWD
STATE="$PACKAGE_DIR/.cross-build"
source ./PKGBUILD
TREE="$PACKAGE_DIR/src/$_srcname"
export CARCH=aarch64
export PACKAGER="Rigo Orozco Díaz <rigo.orozco.d@gmail.com>"
export PATH="/usr/lib/ccache/bin:$PATH"
unset KERNEL_HEADERS_TOOLS CROSS_COMPILE KBUILD_OUTPUT

# Both stages use these paths; only the ARM64 stage writes the native tree.
NATIVE="$STATE/native"
NATIVE_TREE="$NATIVE/src/$_srcname"
REPO="$PACKAGE_DIR/../repo"

prepare_cross_sources() {
    # Dependencies come from Dockerfile.cross, not ARM64 runtime packages.
    makepkg --verifysource --nodeps --ignorearch --noconfirm
    kernel_input_manifest > "$STATE/inputs.sha256"
    makepkg --cleanbuild --nobuild --nodeps --ignorearch --noconfirm
}

compile_kernel() (
    export MAKEFLAGS="ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-"
    export KBUILD_BUILD_USER=build KBUILD_BUILD_HOST=yoga-alarm
    export KBUILD_BUILD_TIMESTAMP="$(date -u -r "$TREE/Makefile")"
    export srcdir="$PACKAGE_DIR/src"

    # Reuse the PKGBUILD targets rather than maintaining another build recipe.
    cd "$srcdir"
    build
)

run_compile_stage() {
    local started=$SECONDS

    sudo chmod -R a+rwX "$PACKAGE_DIR"
    rm -rf -- "$STATE"
    mkdir -p "$STATE"
    exec > >(tee "$STATE/compile.log") 2>&1

    prepare_cross_sources
    compile_kernel
    kernel_require_arm64_elf "$TREE/vmlinux"

    aarch64-linux-gnu-gcc --version > "$STATE/cross-compiler.txt"
    gcc --version > "$STATE/cross-host-compiler.txt"
    sha256sum --check --quiet "$STATE/inputs.sha256"
    kernel_output_manifest "$TREE" > "$STATE/outputs.sha256"

    ccache --show-stats
    printf 'Cross compilation: %s seconds\n' "$((SECONDS - started))"
    touch "$STATE/complete"
}

prepare_arm64_tools() {
    local started=$SECONDS
    local entry filename

    # Keep native kbuild away from the completed kernel's configuration and headers.
    mkdir -p "$NATIVE"
    cp PKGBUILD "$NATIVE/PKGBUILD"
    for entry in "${source[@]}"; do
        if [[ "$entry" == *::* ]]; then
            filename=${entry%%::*}
        else
            filename=${entry##*/}
        fi
        ln -sf "$PACKAGE_DIR/$filename" "$NATIVE/$filename"
    done

    sudo -E pacman -Syu --noconfirm --disable-sandbox
    (cd "$NATIVE"; makepkg --cleanbuild --nobuild --syncdeps --noconfirm)
    gcc --version | tee "$STATE/arm64-compiler.txt"

    cp "$TREE/.config" "$NATIVE_TREE/.config"
    make -C "$NATIVE_TREE" ARCH=arm64 olddefconfig
    make -C "$NATIVE_TREE" ARCH=arm64 -j "$(nproc)" modules_prepare scripts

    printf 'ARM64 tools preparation: %s seconds\n' "$((SECONDS - started))"
    kernel_verify_handoff "$STATE"
}

verify_packaged_outputs() {
    local validation_dir=$1 headers=$2
    local file

    for file in .config Module.symvers System.map vmlinux version; do
        cmp "$TREE/$file" "$headers/$file"
    done
    for file in Image Image.gz; do
        cmp "$TREE/arch/arm64/boot/$file" "$validation_dir/linux-yoga/boot/$file"
    done
}

check_external_module() {
    local headers=$1 module_dir=$2 kernel_release=$3

    mkdir -p "$module_dir"
    cat > "$module_dir/check.c" <<'EOF'
#include <linux/module.h>
static int __init check_init(void) { return 0; }
static void __exit check_exit(void) { }
module_init(check_init);
module_exit(check_exit);
MODULE_LICENSE("GPL");
EOF
    printf 'obj-m := check.o\n' > "$module_dir/Makefile"

    make -C "$headers" ARCH=arm64 M="$module_dir" modules
    kernel_require_arm64_elf "$module_dir/check.ko"
    modinfo -F vermagic "$module_dir/check.ko" | grep -F "$kernel_release "
}

validate_packages() {
    local output_dir=$1 validation_dir=$2
    local started=$SECONDS
    local kernel_release headers

    kernel_release=$(<"$TREE/version")
    headers="$validation_dir/linux-yoga-headers/usr/lib/modules/$kernel_release/build"

    kernel_validate_archives "$output_dir" "$pkgver-$pkgrel" "$kernel_release" "$validation_dir"
    verify_packaged_outputs "$validation_dir" "$headers"
    check_external_module "$headers" "$validation_dir/module" "$kernel_release"
    kernel_verify_handoff "$STATE"

    printf 'Archive and external-module validation: %s seconds\n' "$((SECONDS - started))"
}

cleanup_package_files() {
    if [[ -n "$output_dir" ]]; then
        rm -rf -- "$output_dir"
    fi
    if [[ -n "$validation_dir" ]]; then
        rm -rf -- "$validation_dir"
    fi
}

run_package_stage() (
    # A subshell keeps the temporary paths alive for the EXIT cleanup trap.
    output_dir=
    validation_dir=
    trap cleanup_package_files EXIT

    kernel_verify_handoff "$STATE"
    exec > >(tee "$STATE/package.log") 2>&1
    cat "$STATE/cross-compiler.txt"
    export MAKEFLAGS=ARCH=arm64

    prepare_arm64_tools

    mkdir -p "$REPO"
    output_dir=$(mktemp -d "$REPO/.build-linux-yoga.XXXXXX")
    validation_dir=$(mktemp -d "$STATE/validate.XXXXXX")

    started=$SECONDS
    KERNEL_HEADERS_TOOLS="$NATIVE_TREE" PKGDEST="$output_dir" \
        makepkg --repackage --noextract --syncdeps --noconfirm --force --nosign
    kernel_verify_handoff "$STATE"
    printf 'Packaging: %s seconds\n' "$((SECONDS - started))"

    validate_packages "$output_dir" "$validation_dir"
    update_repo "$REPO" "$output_dir"
    ccache --show-stats
    echo "Kernel and headers published. Logs: $STATE/{compile,package}.log"
)

case "$STAGE" in
    compile) run_compile_stage ;;
    package) run_package_stage ;;
esac
