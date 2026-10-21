# Upstream Linux 7.3 for Yoga C630

`linux-yoga` and `linux-yoga-headers` use the kernel.org Linux 7.3 release with
one local Yoga C630 DisplayPort device-tree patch. No SDM845 downstream patch
stack or kernel driver workaround is applied. The upstream archive SHA-256 was
checked against kernel.org's `v7.x/sha256sums.asc`; package sources, including the
local patch, have SHA-256 checksums in `PKGBUILD`.

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

Use the existing `archlinuxarm-build` Docker image (built from the root
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
was subsequently booted and the display experiments below were performed by the
user. The `7.3-2` DTS patch is checked separately by applying it to pristine 7.3
source and compiling the board DTB; it does not require kernel driver changes.
A normalized comparison of the compiled DTB matches the manually edited
two-lane test DTB used for the display observations below.
A full `7.3-2` kernel/headers package rebuild is still required before installation.

## DisplayPort observations (2026-10-21)

The Yoga boots `7.3.0-yoga` into GNOME Wayland with its internal 1920x1080 panel
and Wi-Fi working. External display support remains experimental. Only the
right-hand USB-C port supports DisplayPort, as described by the Yoga UCSI driver.

The packaged DTS patch makes three changes:

- Enable `mdss_dp`, which is disabled in the upstream board description.
- Add `mode-switch` to `usb_1_qmpphy` for Type-C alternate-mode configuration.
- Set `data-lanes = <0 1>` on `mdss_dp_out`. The two-lane limit follows the
  [earlier Yoga C630 DP proposal](https://lkml.iu.edu/2208.1/02295.html).

With only DP enabled and the mode switch added, the LG monitor appeared in GNOME
but link training failed (`max v_level reached`) and the desktop stalled.
The driver defaults to four lanes without a board limit. Adding the two-lane
limit enabled video output: 3840x2160 at 30 Hz and 2560x1440 near 60 Hz were
reported working. This is evidence for the tested lane limit, not proof that all
adapter combinations or hotplug paths work.

Both the direct Synaptics VMM7100 USB-C-to-HDMI cable (`06cb:7100`) and the Anker
HDMI dock negotiate the same observed display settings:

| Setting | Direct cable and dock |
| --- | --- |
| DP link rate | `540000` (HBR2, 5.4 Gbit/s per lane) |
| Lane count | 2 |
| Mode | 3840x2160 at 30 Hz |
| Pixel clock | 297000 kHz |
| Pixel depth | 24 bpp |
| Voltage swing / pre-emphasis | 0 / 0 |

Two HBR2 lanes provide 8.64 Gbit/s of payload after 8b/10b encoding. This fits the
observed 4K30 limit for ordinary uncompressed 24-bit RGB. Increasing the DT lane
count is not a demonstrated way to obtain 4K60 on this board.

### Direct cable versus dock

| Operation / event | Direct VMM7100 cable | Anker HDMI dock |
| --- | --- | --- |
| Display output with two-lane DTS | Works | Works |
| Physical USB-C unplug/replug | Unplug hangs/crashes the system | User reports it works without panic or GNOME hang |
| Disable display in GNOME, then unplug | Works as a workaround | Works |
| Vblank/frame-done timeouts in captured disconnect logs | Present | None |
| External abort in captured log | Present | None |
| Duplicate partner-altmode warnings | Offsets 1 through 29 | Same warnings recur after reconnect |

The second dock capture (`yoga-dmesg-hub-2.log`) records physical USB-C removal
at about 314.4 seconds and reconnection at 342.2 seconds. No display timeouts or
external aborts appear during that cycle. There is an unexpected interrupt at
reconnect. The dock logs also contain an earlier AUX warning and USB reset /
re-enumeration errors, so they are not completely error-free.

The common UCSI code filters repeated DisplayPort SVID `0xff01` entries from the
EC, but continues querying through offset 29. The warning bursts take about
15 seconds. They occur with both adapters and are not sufficient by themselves
to explain the direct-cable crash. Their effect on event timing is unproven.

The direct-cable capture (`yoga-unplug.log`) shows:

1. USB disconnect at about 326.45 seconds.
2. Vblank / commit timeout at about 327.62 seconds.
3. A synchronous external abort in the `disp_snapshot` worker, with
   `msm_disp_snapshot_add_block -> msm_dp_snapshot` in the call trace.

The snapshot helper reads DP registers using `readl_relaxed()`. Its `power_on`
check did not prevent this fault. Access to an unclocked/powered-down block or
an unsafe register range is a hypothesis, not an established root cause.
An earlier panic photo also shows a fatal asynchronous SError while the EC
hotplug thread was in `msm_dp_display_atomic_disable -> msm_dp_ctrl_push_idle`.
These are separate captures: the snapshot fault explains one observed abort,
but does not establish that suppressing diagnostics would fix the whole unplug
failure.

### Where to investigate next

Keep the working two-lane DTS while investigating kernel driver behavior:

- Compare direct-cable and dock HPD, Type-C orientation/mux, DP disable and
  runtime-PM/clock events with monotonic timestamps. Match display mode and USB-C
  plug orientation. The identical negotiated bandwidth makes bandwidth alone an
  unlikely explanation for the differing unplug behavior.
- Trace the Yoga EC/UCSI notification through the AUX HPD bridge and DRM
  hotplug/atomic-disable path. Check when the stream, link clocks and combo PHY
  are stopped relative to connector notifications and framebuffer-console work.
- Inspect synchronization between `msm_dp_snapshot()` and DP teardown. A boolean
  `power_on` check alone may race with shutdown. A diagnostic build that skips
  only DP register snapshots could isolate the secondary abort, but would not
  prove that the initial vblank timeout or other teardown faults are fixed.
- Compare events across direct-cable USB-C removal, dock USB-C removal, HDMI-only
  removal and monitor power off/on. Record cable orientation and mode; test lower
  modes separately if useful. Existing logs do not prove the cable is defective.
- Investigate EC duplicate enumeration separately, including whether the long
  query sequence delays hotplug handling. Do not treat warning suppression as
  a display teardown fix.

Useful captures while the monitor is working:

```sh
sudo find /sys/kernel/debug/dri -name dp_debug -exec cat {} +
echo 0x106 | sudo tee /sys/module/drm/parameters/debug
```

Capture a reproduction on another machine so received output survives a crash
(replace `YOGA_IP` with the Yoga's address):

```sh
ssh -t rigo@YOGA_IP 'sudo dmesg --follow --color=never' | tee yoga-unplug.log
```

After testing, restore the previous DRM debug mask (normally zero). SSH logging
is best effort: the previous journal stopped at the first abort and pstore was
empty, while live capture retained the initial fault trace. Keep any first
exception, register dump and full call trace, not just the final panic.

No diagnostic-suppression or driver teardown patch is included in this package.
Use the dock, or disable the external display in GNOME before unplugging the
direct cable, for normal operation.

## Hardware acceptance and recovery

Before installation, save the working kernel and headers packages and back up
`/boot/Image`, `/boot/Image.gz`, `/boot/dtbs`, `/boot/initramfs-linux.img` and
`/boot/initramfs-linux-fallback.img` to separate recovery storage. The old and new
packages share these boot paths. Have a bootable recovery medium ready; the
fallback initramfs also uses the new kernel and is not an old-kernel fallback.

Install the matching kernel and headers packages together on the target. Verify
that `/boot` is mounted and initramfs generation succeeds before rebooting.

Boot, internal display, Wi-Fi and the external-display observations above have
been reported on a Yoga C630. Complete hardware acceptance remains pending:

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
