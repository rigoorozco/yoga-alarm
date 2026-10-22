# RTC and UEFI on the Yoga C630

Kernel package `linux-yoga` **7.3-3** enables read-only UEFI variables through
Qualcomm QSEECOM and reads the PM8998 RTC's persisted `RTCInfo` offset. The
tested EDK II AArch64 Shell **26H2** can set firmware date and time before Linux
boots.

## Confirmed on the device (2026-10-23)

After setting time in EDK II and installing the patched kernel and board DTB,
the user reported:

- Shell date and time survived rebooting back into the shell.
- QSEECOM set up the `qcom.tz.uefisecapp` client and registered efivars operations.
- efivarfs exposed `RTCInfo` with the expected 16-byte size.
- `timedatectl` showed matching RTC and UTC time while reporting
  `System clock synchronized: no` and `NTP service: active`.

These observations confirm working firmware-variable reads and the RTC offset
path. They support the firmware setting being available to Linux before NTP
synchronization. Persistence across a complete power loss was not reported.

## Install and boot the EDK II Shell

The [shell package](../packages/edk2-shell-aa64/PKGBUILD) pins the tested
[26H2 AArch64 release](https://github.com/pbatard/UEFI-Shell/releases/tag/26H2),
built from EDK II stable202608, with SHA-256:

```text
ce22900f22bce4e31edc26adc7bdb7608ece852d24370a9cf4095e4a2be5aa9e
```

With the yoga-alarm repository configured and the package published:

```sh
sudo pacman -Syu edk2-shell-aa64
```

Alternatively, build and install it locally on AArch64:

```sh
cd packages/edk2-shell-aa64
makepkg -si
```

Keep the ESP mounted at `/boot` when installing, upgrading, or removing this
package. Pacman manages both files:

```text
/boot/EFI/tools/edk2-shell-yoga.efi
/boot/loader/entries/edk2-shell-yoga.conf
```

No manual copying, bootloader update, or initramfs regeneration is needed.
Check the entry with `bootctl list`, then select **EDK II UEFI Shell (Yoga)**
at boot. Hold Space during startup if the menu is hidden. The shell is a UEFI
application; installing it does not flash replacement firmware.

If these exact destination files already exist from a manual installation,
review and back them up before resolving any pacman file conflict. Earlier
manually installed entries at other paths remain separate.

For a USB alternative, place an AARCH64 shell binary on a FAT32 USB drive as
`EFI/BOOT/BOOTAA64.EFI` and boot that drive. A platform developer also describes
[booting the shell on the C630 through GRUB](https://github.com/aarch64-laptops/build/issues/25).

## Set firmware time

In the shell, inspect the current values and supported syntax:

```text
date
time
help date
help time
```

Set the current date and **UTC** time. These values are examples; replace them
with the actual date and UTC time:

```text
date 10/23/2026
time 18:45:00 -tz 0 -d 0
```

Read `date` and `time` again, then reboot into the shell to check persistence.
Use `exit` to return to systemd-boot. EDK II's commands call firmware
[`GetTime()` and `SetTime()`](https://github.com/tianocore/edk2/blob/master/ShellPkg/Library/UefiShellLevel2CommandsLib/TimeDate.c).
If they fail, a small AArch64 `.efi` application can print the exact service
status for diagnosis; it still depends on firmware support.

## Verify Linux RTC reads

Install the matching patched kernel and DTB using the [kernel guide](kernel.md).
Ensure the boot entry loads `/dtbs/qcom/sdm850-lenovo-yoga-c630.dtb` on the ESP,
rather than an older manually edited RTC test DTB.

```sh
uname -r
journalctl -k -b --no-pager | grep -Ei 'qseecom|uefisecapp|efivar|rtc'
findmnt /sys/firmware/efi/efivars
```

Expect client setup for `uefisecapp` and `Registered efivars operations`.
If efivarfs is not mounted:

```sh
sudo mount -t efivarfs efivarfs /sys/firmware/efi/efivars
```

Check the variable, active DT properties, and RTC time:

```sh
sudo stat -c '%n: %s bytes' \
  /sys/firmware/efi/efivars/RTCInfo-882f8c2b-9646-435f-8de5-f208ff80c1bd
ls /sys/class/rtc/rtc0/device/of_node/qcom,uefi-rtc-info
test ! -e /sys/class/rtc/rtc0/device/of_node/allow-set-time
sudo hwclock --rtc=/dev/rtc0 --show --utc
timedatectl
```

The expected variable file is 16 bytes: four efivarfs attribute bytes plus the
12-byte Qualcomm RTC structure. Compare RTC time with UTC. To check boot-time
initialization separately from a later NTP correction, inspect the early
`setting system clock` kernel message. Repeat after reboot.

## Limitations and troubleshooting

Linux can read variables but cannot persist changes through this backend.
`hwclock --systohc` cannot save a new offset when a firmware-variable write is
required. NTP synchronizes the system clock independently; firmware time may
need periodic correction through the shell.

| Symptom | Meaning or next check |
| --- | --- |
| RTC reads a date in January 1970 | Check that the patched kernel and DTB are active and that `RTCInfo` is readable. The raw counter needs its calendar offset. |
| `ENODEV` when setting RTC time | The driver can return this when neither NVMEM nor UEFI offset storage is configured. |
| `disallowed SPMI write to sid=0, addr=0x6046` / `EPERM` | Linux lacks write ownership of the PMIC counter. `allow-set-time` cannot grant that ownership. Remove the property and use the offset path. |
| `qseecom: untested machine, skipping` | The running kernel lacks the C630 platform enablement. |
| efivarfs mount returns `Operation not supported` | No variable backend is available. Check QSEECOM client setup and registration. |
| RTC probe remains deferred | The UEFI offset property makes the driver wait for the variable backend. |
| `RTCInfo` is absent or malformed | RTC probing can fail; variable enumeration alone does not establish a valid offset. |
| EFI memory-attributes warning | This warning remained in the successful device boot; it did not prevent QSEECOM variable access. |

The successful boot retained `efi=novamap`. `efi=debug,novamap` provides extra EFI
logging but does not enable missing QSEECOM platform support. Direct PMIC writes
remain restricted, and the packaged DTS does not enable `allow-set-time`.

## Kernel patch provenance

The [kernel package](../packages/linux-yoga/PKGBUILD) backports patches
**1, 2, 3, 4, and 8** from Dmitry Baryshkov's
[June 2025 v4 series](https://lore.kernel.org/r/20250625-more-qseecom-v4-0-aacca9306cee@oss.qualcomm.com).
Each patch retains its original authorship, review tags, and message link.

| Local patch | Purpose |
| --- | --- |
| `0002` | Return `EFI_WRITE_PROTECTED` instead of calling a missing write callback. |
| `0003` | Pass machine quirks from SCM through QSEECOM to application clients. |
| `0004` | Register read-only UEFI operations when the quirk is set. |
| `0005` | Enable the C630 with read-only UEFI variables. |
| `0006` | Label the PM8998 RTC and enable `qcom,uefi-rtc-info`. |

The quirk lookup is adapted to Linux 7.3's `of_machine_device_match()` code;
other hunks have refreshed context. Unrelated SC8280XP CRD enablement, an
optional boot parameter, and the SoC-wide allowlist rework are omitted.
Existing allowlisted machines retain their write-capable backend.

The series explains that persistent writes need coordination with the UFS
storage shared between Linux and secure firmware. Its
[read-only support discussion](https://patchew.org/linux/20250621-more-qseecom-v2-0-6e8f635640c5%40oss.qualcomm.com/20250621-more-qseecom-v2-2-6e8f635640c5%40oss.qualcomm.com/)
also covers drift and protection against missing write callbacks.

## Build validation (2026-10-23)

All six package patches, including DisplayPort, apply to pristine Linux 7.3 in
order with zero fuzz. `makepkg --verifysource` validates every source checksum.
The merged configuration enables EFI, efivarfs, QSEECOM, UEFISECAPP, and the
PM8xxx RTC. GCC 13.3.0 successfully cross-builds `Image`, `Image.gz`, and modules.

The C630 DTB builds with symbols and contains `pm8998_rtc` and
`qcom,uefi-rtc-info`, without `allow-set-time`. DTC reports warnings in existing
SoC nodes but no errors. Both `7.3-3` AArch64 package archives were built; their
metadata and packaged images/DTB were verified. The compressed RTC module is
an AArch64 ELF object.

Headers reuse the previously validated ARM64 Linux 7.3 utilities after comparing
their source with the current tree. An external module compiled and linked
against the extracted headers archive in the ARM64 Docker image. Its GCC 15.2.1
compiler emits the expected version warning for the GCC 13.3.0 kernel.
See the [kernel guide](kernel.md) for the clean Docker build procedure.
