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
scripts/run-docker-build.sh
```

Build only one package, or select several:

```sh
scripts/run-docker-build.sh edk2-shell-aa64
scripts/run-docker-build.sh qmic-git pd-mapper-git
scripts/run-docker-build.sh --help
```

Manually refresh the Docker image with the latest base image and installed
Arch Linux ARM packages:

```sh
scripts/refresh-docker-image.sh
```

This rebuilds all image layers, so the refresh itself can take a while. Later
package builds reuse the updated image and only upgrade packages changed since
the refresh. Run it periodically rather than before every build. It does not
build packages or update `packages/repo`. Like the build launcher, it supports
`IMAGE_NAME` and `PLATFORM` environment overrides and registers ARM64 emulation.

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
scripts/sign-packages.sh --key 041A82E390EAD451
scripts/rebuild-repo.sh
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
scripts/rebuild-repo.sh
```

This indexes all remaining package archives without rebuilding packages or changing
their signatures. It can be run from any directory. Set `REPO_DIR` to use another
repository directory.

Package archives in `packages/repo` can be signed after they are built:

```sh
scripts/sign-packages.sh --key 041A82E390EAD451
```

Export the public key file that users import with `pacman-key`:

```sh
gpg --armor --export 041A82E390EAD451 > yoga-alarm-packaging.pub
```

Only publish the exported public key. Do not publish `~/.gnupg`, secret-key
exports, or files created with `gpg --export-secret-keys`.

## Documentation

See the [documentation index](docs/README.md) for kernel build and recovery
instructions, RTC/UEFI setup, and DisplayPort findings.

## Notes

- Packages are built for `aarch64`.
- The repository database is named `yoga-alarm`.
- Repository database signatures are optional; package signatures are required
  by the documented pacman configuration.
