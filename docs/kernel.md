# Kernel builds and migration history

`linux-yoga` and `linux-yoga-headers` use the kernel.org Linux 7.3 release with
local Yoga C630 DisplayPort and read-only QSEECOM UEFI-variable patches. No SDM845
downstream patch stack is applied. The upstream archive SHA-256 was
checked against kernel.org's `v7.x/sha256sums.asc`; package sources, including the
local patches, have SHA-256 checksums in `PKGBUILD`.

Package release `7.3-3` also backports patches 1–4 and 8 from Dmitry Baryshkov's
June 2025 v4 C630 QSEECOM series. It enables read-only firmware variables and
lets the RTC driver read the persisted `RTCInfo` offset. See
the [RTC and UEFI guide](rtc.md) for provenance, limitations, and device validation.

Package release `7.3-2` applies
`0001-arm64-dts-qcom-sdm850-lenovo-yoga-c630-enable-dp.patch` in `prepare()`
before merging the configuration. It changes the source board DTS, so package
builds no longer require hand-editing a decompiled DTB.

Configuration is merged in this order: upstream ARM64 `defconfig`, `arch.config`,
`yoga.config`, then `trim.config`. `olddefconfig` resolves upstream dependencies.
The local Yoga fragment preserves supported platform settings and package policy
previously supplied by downstream `sdm845.config` and `misc.config`. The kernel
release suffix is `-yoga`; the userspace `pd-mapper` service remains in use.

## Compatibility

Upstream includes the Yoga C630 device tree, EC, battery and USB-C UCSI drivers.
The downstream-only QDSP6 voice and Qualcomm SPMI haptics config symbols are not
available and are not enabled. Their absence does not establish a regression in
Yoga speakers or microphone, which still require hardware testing.
Upstream marks the Qualcomm QCE crypto accelerator as broken; it remains
disabled and CPU crypto implementations remain available.

The upstream device tree differs from the previous downstream tree in cluster
suspend settings, IPA firmware setup and USB PHY supply assignments. These
upstream definitions are retained unchanged. In particular, USB-C, suspend and
IPA/modem operation need device verification. Existing firmware and ALSA routing
packages remain necessary.

## Build only the kernel

Run the commands below from the repository root. Use the existing
`archlinuxarm-build` Docker image (built from the root
`Dockerfile`) and the same ARM64 emulation setup as `scripts/run-docker-build.sh`:

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64
docker run --rm --platform linux/arm64 \
  -e MAKEFLAGS=ARCH=arm64 \
  -v "$PWD/packages/linux-yoga:/build" -w /build \
  archlinuxarm-build /bin/bash -c 'makepkg --verifysource && makepkg --cleanbuild --force --nodeps'
```

The image must already contain the dependencies declared in `PKGBUILD`.
This command creates local packages; it does not sign them or publish a release.

## Validation of this migration

Linux 7.3 `Image`, `Image.gz`, modules and all enabled DTBs were cross-compiled
with GCC 13.3.0 using the final merged configuration. The Yoga C630 DTB was
produced with symbols (`DTC_FLAGS=-@`). ARM64 build utilities were compiled in the
existing Docker image and retained in the headers package. Local packaging used
an AArch64 makepkg configuration and the AArch64 strip tool.

An external module compiled and linked successfully against these headers in the
ARM64 Docker image with GCC 15.2.1. This emits the expected compiler-version
mismatch warning because the kernel was built with GCC 13.3.0. Use a matching
compiler when building additional modules where possible.

The slower fully emulated kernel compilation was stopped after the native cross
build passed. These build and external-module results describe the initial
`7.3-1` migration, not a completed end-to-end emulated Docker build. The device
was subsequently booted and the user performed the
[DisplayPort experiments](displayport.md). The `7.3-2` DTS patch is checked
separately by applying it to pristine 7.3
source and compiling the board DTB; it does not require kernel driver changes.
A normalized comparison of the compiled DTB matches the manually edited
two-lane test DTB used for the [DisplayPort observations](displayport.md).
The `7.3-3` kernel image, modules, and C630 DTB cross-build checks are recorded in
the [RTC and UEFI guide](rtc.md). Both AArch64 package archives were built from those
results; an external module also built against the extracted headers archive
in the ARM64 Docker image. On 2026-10-23 the user confirmed QSEECOM variable
access and a correct RTC date on the Yoga before NTP synchronization.

## Hardware acceptance and recovery

Before installation, save the working kernel and headers packages and back up
`/boot/Image`, `/boot/Image.gz`, `/boot/dtbs`, `/boot/initramfs-linux.img` and
`/boot/initramfs-linux-fallback.img` to separate recovery storage. The old and new
packages share these boot paths. Have a bootable recovery medium ready; the
fallback initramfs also uses the new kernel and is not an old-kernel fallback.

Install the matching kernel and headers packages together on the target. Verify
that `/boot` is mounted and initramfs generation succeeds before rebooting.

Boot, internal display, Wi-Fi, read-only UEFI/RTC access, and the
[external-display observations](displayport.md) have been reported on a Yoga
C630. Complete hardware acceptance remains pending:

- Boot, root filesystem and module loading.
- Display, backlight, keyboard and touchpad.
- Wi-Fi and Bluetooth.
- Speakers, microphone and headphones with the existing ALSA routing package.
- Battery status, charging and USB-C peripherals in both connector orientations.
- Suspend/resume over repeated cycles, including wireless and audio afterward.
- IPA/modem operation if used.

If the new kernel cannot boot, use recovery media to restore the saved boot
files and reinstall the previous packages into the mounted target system.
Regenerate the previous kernel's initramfs before rebooting.
