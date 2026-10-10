# How to Run the Exporter on a Small Device

On a router of 32 or 64 MB of RAM and 4 to 16 MB of flash, install the base package alone, add only the collectors you need, and leave out the command line and the LuCI app where the flash is short. The figures below were measured on QEMU's MIPS 24Kc (`make bench-qemu`, 32-bit, as MT7621-class and ath79-class routers are) and on a Cortex-A53 access point.

## Prerequisites

- OpenWrt 25.12, with the exporter's feed added: see [How to install the exporter](install.md#1-add-the-feed).
- The device's free flash and RAM: `df -h /overlay` and `free`.

---

## 1. Check what it takes

**Flash.** Installed sizes, as apk counts them, uncompressed; on a JFFS2 overlay, which compresses with LZMA, the base package takes about 120 KiB. The packages install their code without comments:

| Package | Installed |
| :--- | :--- |
| `ucode-prometheus-exporter`, the base package | 264 KiB |
| what it needs besides, on an image with LuCI | `uhttpd-mod-ucode` and `ucode-mod-zlib`, 12 KiB each (mipsel) |
| what it needs besides, on an image without LuCI | `uhttpd`, `uhttpd-mod-ucode`, `rpcd-mod-ucode`, `ucode-mod-uloop`, `-zlib`, `-digest` and `-log`: some 200 KiB (x86_64's sizes) |
| a collector's package | 1 to 12 KiB |
| `ucode-prometheus-exporter-cli`, the command line, and `ucode-docopt` | 10 and 43 KiB |
| `luci-app-prometheus-exporter` | 54 KiB |

On a 1.6 MB JFFS2 overlay (26 blocks of 64 KiB, LZMA, as a small access point's `rootfs_data`), empty but for what they install, the base package, the LuCI app and three collectors (`-wifi`, `-hostapd_stations`, `-thermal`) take 296 KiB of the overlay, apk's database included, and leave room for 1,092 KiB more; upgrading them in place, which writes each new file beside the old one, needs 20 KiB more. Measured on QEMU's malta with an mtdram device; the overlay's other files come on top, so check `df /overlay` first.

`ucode`, `ucode-mod-fs`, `-ubus`, `-uci` and `-rtnl` are in every 25.12 image with Wi-Fi. Of the `-full` group, the programs of ethtool (`ethtool`, 72 KiB) and qdisc (`tc-tiny` and `kmod-sched-core`, 279 and 172 KiB) take more than all its collectors together.

**RAM.** uhttpd holds the handler and its collectors for as long as it runs: about 1.0 MB of its own with the base collectors on the 24Kc, 1.5 MB with every collector of the `-full` group, besides uhttpd's own. A scrape forks a process, and the collectors' child from it, which take about 2 MB more with the base collectors and 4.5 MB with every one, for the scrape's time. In a QEMU guest of 64 MB, the base package, the `-full` group and the command line installed, the service served all 36 collectors, its uhttpd held 1.7 MB (RssAnon), and the guest had 14.6 MB available.

**`memory_limit`.** Each of the exporter's processes may take `memory_limit` MB of data; 0, the default, is a quarter of the RAM, at most 64. The least under which the handler loads and a scrape of its collectors succeeds is 3 MB with the base collectors and 5 MB with every one on the 24Kc (7 MB on a 64-bit CPU). A quarter of a 32 MB router's RAM, some 6 MB, is enough for either; one of 64 MB gets about 13 MB. See [memory_limit's floor](../explanation/performance.md#memory-floor).

## 2. Install the base package alone

```sh
apk update
apk add ucode-prometheus-exporter
```

Neither the command line nor the LuCI app is needed to serve: `service prometheus-exporter check` checks the configuration without the command, and `uci` sets it. Add `ucode-prometheus-exporter-cli` only where you push metrics from cron or check a collector, and `luci-app-prometheus-exporter` only where LuCI is.

## 3. Add only the collectors you need

Install collectors one by one rather than a group: the `-full` group brings `ethtool` and `tc`, and the collectors that cost most on a slow CPU. What each costs, held at rest and in a scrape on the 24Kc and the A53, is in [What each collector costs](../explanation/performance.md#each-collector). On a small router:

- **32 MB of RAM, 4 MB of flash**: the base collectors. Disable those you do not use (see [How to choose collectors](choose-collectors.md#disable-a-collector)); each disabled collector is neither held nor run.
- **64 MB of RAM, 8 MB of flash**: add what the device has: `-wifi` on an access point, `-netstat`, `-openwrt`, `-wireguard`, `-thermal` or `-hwmon` where it has sensors.
- **Leave out** `nat_traffic` on a router with a large connection table (5.6 s for 20,000 connections on the 24Kc); `ethtool` (1.4 s on the benchmark's 17 ports on the 24Kc, and its program's flash); `dhcp_leases` where there are thousands of leases; `hostapd_stations` where `wifi` with `stations` does; `qdisc` without SQM; and `unbound` unless you run Unbound, whose statistics a scrape parses, 30 ms on the 24Kc.

```sh
apk add ucode-prometheus-exporter-wifi ucode-prometheus-exporter-netstat
```

## 4. Check what it holds

```sh
service prometheus-exporter check
for p in $(pidof uhttpd); do grep -q handler.uc /proc/$p/cmdline && grep -E '^(RssAnon|VmData)' /proc/$p/status; done
free
```

`check` says the `memory_limit` the service runs under, and the collectors it serves. A collector that runs out of memory fails alone, `COLLECTOR_KILLED`, and the others are served: raise `memory_limit`, or leave that collector out.

---

## See also

- [Performance on small routers](../explanation/performance.md): what a scrape costs, and what uhttpd holds.
- [Files and packages](../reference/files.md): what each package installs and depends on.
- [UCI configuration](../reference/uci-config.md): `memory_limit`.
