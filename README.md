# Yoga ALARM

Arch Linux ARM package build files for the Lenovo Yoga C630 / Snapdragon 850
(`sdm845`) platform.

The repository builds a small local pacman repository under `packages/repo`.
It includes the Yoga kernel package, firmware package, and userspace Qualcomm
services used by this device.

## Packages

Package sources live under `packages/`:

- `linux-yoga` - upstream Linux 7.3 with Yoga C630 DisplayPort and read-only UEFI RTC offset support.
- `firmware-lenovo-yoga-c630` - device firmware package.
- `alsa-ucm-conf-yoga-c630` - Yoga C630 ALSA UCM routing and WirePlumber format fixes.
- `edk2-shell-aa64` - pinned AArch64 EDK II Shell 26H2.
- `pd-mapper-git` - Qualcomm protection-domain mapper.
- `qmic-git` - Qualcomm IPC helper tooling.
- `qrtr-git` - Qualcomm QRTR tooling.
- `tqftpserv-git` - Qualcomm TFTP server.

Built packages and the pacman repository database are placed in:

```sh
packages/repo
```

## Build

Build every package from the host using Docker (including the kernel):

```sh
scripts/host/run-docker-build.sh
```

Build only one package, or select several:

```sh
scripts/host/run-docker-build.sh edk2-shell-aa64
scripts/host/run-docker-build.sh qmic-git pd-mapper-git
scripts/host/run-docker-build.sh --help
```

On an x86 Docker host, `linux-yoga` is cross-compiled in an Arch x86 container
using the ARM64 cross toolchain. The ARM64 container prepares executable headers
tools, creates both kernel packages and checks them by building an external
module before publishing. Other packages still build in the ARM64 container.
Kernel sources are prepared cleanly on each run; ccache survives between runs.

To use the fully emulated kernel build instead:

```sh
KERNEL_BUILD_MODE=emulated scripts/host/run-docker-build.sh linux-yoga
```

Cross mode is the default and requires x86 Docker. Set `KERNEL_BUILD_MODE=emulated`
on other hosts. `CROSS_IMAGE_NAME` overrides the default
`archlinuxarm-kernel-cross` image; `IMAGE_NAME` and `PLATFORM` still select the
ARM64 image and platform. A workspace lock prevents concurrent kernel builds
through the launcher. See [kernel build details](docs/kernel.md#build-only-the-kernel)
for the stage handoff, validation and logs.

The Docker image enables makepkg's built-in ccache support for package builds.
The x86 cross-build stage uses the same compiler wrappers and cache.
The cache is stored in the Docker volume `yoga-alarm-ccache`
so it survives container removal and image rebuilds. The first build fills the
cache; later builds can reuse matching compiler outputs. The cache defaults to
a 10 GB limit. Override the limit or volume name when launching a build:

```sh
CCACHE_MAXSIZE=20G CCACHE_VOLUME=yoga-alarm-ccache scripts/host/run-docker-build.sh linux-yoga
```

Inspect cache usage and hit statistics after a build:

```sh
docker run --rm --platform linux/arm64 \
  --mount type=volume,source=yoga-alarm-ccache,target=/usr/local/build/.cache/ccache \
  -e CCACHE_DIR=/usr/local/build/.cache/ccache \
  archlinuxarm-build ccache --show-stats
```

Manually refresh the Docker image with the latest base image and installed
Arch Linux ARM packages:

```sh
scripts/host/refresh-docker-image.sh
```

This refreshes both the ARM64 and x86 cross-build images. Use
`scripts/host/refresh-docker-image.sh --arm64-only` to refresh just the ARM64 image,
including on hosts that cannot run the x86 image natively.
This rebuilds all image layers, so the refresh itself can take a while. Later
package builds reuse the updated image and only upgrade packages changed since
the refresh. Run it periodically rather than before every build. It does not
build packages or update `packages/repo`. Like the build launcher, it supports
`IMAGE_NAME`, `PLATFORM` and `CROSS_IMAGE_NAME` environment overrides and registers
ARM64 emulation.

The scripts can be called from any directory. Package names are validated before
Docker starts, duplicates are ignored, and builds run in dependency order.
For `pd-mapper-git` and `tqftpserv-git`, a suitable installed or repository
`qrtr-git` package is reused; otherwise it is built first. Other dependencies
are installed using pacman.

The Docker build runs an ARM64 Arch Linux environment and writes package
artifacts into `packages/repo`. Only outputs from the current build are published,
including split packages such as the kernel headers. A successful build replaces
archives with matching filenames and removes older releases of the same package
and architecture. Other packages and architectures are preserved. Failed builds
or database generation leave previously published package archives intact.

The release number (the `-1` in `name-version-1-aarch64.pkg.tar.*`) comes from
`pkgrel` in the PKGBUILD. The build scripts do not increment it. Rebuilding the
same version and release overwrites it; changing `pkgver` or `pkgrel` produces a
new filename. Increment `pkgrel` deliberately when installed systems should pick
up a changed build through a normal upgrade.

Builds do not sign packages. Replacing an archive removes its previous signature;
run the signing script after building and rebuild the database afterward to
include the new signatures:

```sh
scripts/host/sign-packages.sh --key 041A82E390EAD451
scripts/host/rebuild-repo.sh
```

## Use The Repository

The package repository is consumed from the `packages-latest` GitHub release.
Import and locally trust the package signing key on the target system:

```sh
curl -LO https://github.com/rigoorozco/yoga-alarm/releases/download/packages-latest/yoga-alarm-packaging.pub
sudo pacman-key --add yoga-alarm-packaging.pub
sudo pacman-key --lsign-key 041A82E390EAD451
```

Then add this to `/etc/pacman.conf`:

```ini
[yoga-alarm]
SigLevel = Required DatabaseOptional
Server = https://github.com/rigoorozco/yoga-alarm/releases/download/packages-latest
```

Then sync and install packages:

```sh
sudo pacman -Sy
sudo pacman -S linux-yoga firmware-lenovo-yoga-c630 alsa-ucm-conf-yoga-c630
```

After installing the audio fix, log out and back in or restart the user audio
services:

```sh
systemctl --user restart wireplumber pipewire pipewire-pulse
```

## Package Signing

After manually removing unwanted package archives and their signatures from
`packages/repo`, regenerate the repository database using the existing Docker image:

```sh
scripts/host/rebuild-repo.sh
```

This indexes all remaining package archives without rebuilding packages or changing
their signatures. It can be run from any directory. Set `REPO_DIR` to use another
repository directory.

Package archives in `packages/repo` can be signed after they are built:

```sh
scripts/host/sign-packages.sh --key 041A82E390EAD451
```

Export the public key file that users import with `pacman-key`:

```sh
gpg --armor --export 041A82E390EAD451 > yoga-alarm-packaging.pub
```

Only publish the exported public key. Do not publish `~/.gnupg`, secret-key
exports, or files created with `gpg --export-secret-keys`.

## Script Layout and Tests

Host commands live in `scripts/host/`, container scripts in `scripts/docker/`,
and sourced helpers in `scripts/lib/`. Their tests live in `scripts/tests/`.

Run the workflow tests (requires `bsdtar`):

```sh
python3 -m unittest discover -s scripts/tests -v
```

Set `YOGA_TEST_DOCKER=1` to also run the ARM64 integration test against the
existing `archlinuxarm-build` image.

## Documentation

See the [documentation index](docs/README.md) for kernel build and recovery
instructions, RTC/UEFI setup, and DisplayPort findings.

## Notes

- Packages are built for `aarch64`.
- The repository database is named `yoga-alarm`.
- Repository database signatures are optional; package signatures are required
  by the documented pacman configuration.
