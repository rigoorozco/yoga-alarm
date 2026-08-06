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
sudo pacman -S linux-yoga firmware-lenovo-yoga-c630
```

## Package Signing

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

## Notes

- Packages are built for `aarch64`.
- The repository database is named `yoga-alarm`.
- Repository database signatures are optional; package signatures are required
  by the documented pacman configuration.
