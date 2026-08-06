# Yoga ALARM

Arch Linux ARM package build files for the Lenovo Yoga C630 / Snapdragon 850
(`sdm845`) platform.

The repository builds a small local pacman repository under `packages/repo`.
It includes the Yoga kernel package, firmware package, and userspace Qualcomm
services used by this device.

## Packages

Package sources live under `packages/`:

- `linux-yoga` - Yoga C630 kernel package.
- `firmware-lenovo-yoga-c630` - device firmware package.
- `pd-mapper-git` - Qualcomm protection-domain mapper.
- `qmic-git` - Qualcomm IPC helper tooling.
- `qrtr-git` - Qualcomm QRTR tooling.
- `tqftpserv-git` - Qualcomm TFTP server.

Built packages and the pacman repository database are placed in:

```sh
packages/repo
```

## Build

Build packages from the host using Docker:

```sh
scripts/run-docker-build.sh
```

The Docker build runs an ARM64 Arch Linux environment and writes package
artifacts into `packages/repo`.

The build script currently controls which packages are built in:

```sh
scripts/build-packages.sh
```

## Use The Repository

The package repository is consumed from the `packages-latest` GitHub release.
Add this to `/etc/pacman.conf` on the target system:

```ini
[localrepo]
SigLevel = Optional TrustAll
Server = https://github.com/rigoorozco/yoga-alarm/releases/download/packages-latest
```

Then sync and install packages:

```sh
sudo pacman -Sy
sudo pacman -S linux-yoga firmware-lenovo-yoga-c630
```

## Notes

- Packages are built for `aarch64`.
- The repository database is named `localrepo`.
- Package signing is not currently enforced by the generated repo config.
