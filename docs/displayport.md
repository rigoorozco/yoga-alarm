# DisplayPort on the Yoga C630

Observations recorded on 2026-10-21. For kernel builds and installation, see
[kernel.md](kernel.md).

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

## Direct cable versus dock

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

## Where to investigate next

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

