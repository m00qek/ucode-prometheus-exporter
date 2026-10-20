# How to Run the Exporter on a Small Device

On a router with 32 or 64 MB of RAM and 4 to 16 MB of flash:

- install the base package alone,
- add only the collectors you need, and
- leave out the command line and the LuCI app where flash is short.

The figures below were measured on QEMU's MIPS 24Kc (`make bench-qemu`, 32-bit, like MT7621-class and ath79-class routers) and on a Cortex-A53 access point.

## Prerequisites

- OpenWrt 25.12, with the exporter's feed added: see [How to install the exporter](install.md#1-add-the-feed).
- The device's free flash and RAM: `df -h /overlay` and `free`.

---

## 1. Check what it takes

**Flash.** The table gives installed sizes as apk counts them, uncompressed. On a JFFS2 overlay, which compresses with LZMA, the base package takes about 120 KiB. The packages install their code without comments.

| Package | Installed |
| :--- | :--- |
| `ucode-prometheus-exporter`, the base package | 264 KiB |
| what it needs besides, on an image with LuCI | `uhttpd-mod-ucode` and `ucode-mod-zlib`, 12 KiB each (mipsel) |
| what it needs besides, on an image without LuCI | `uhttpd`, `uhttpd-mod-ucode`, `rpcd-mod-ucode`, `ucode-mod-uloop`, `-zlib`, `-digest` and `-log`: some 200 KiB (x86_64's sizes) |
| a collector's package | 1 to 12 KiB |
| `ucode-prometheus-exporter-cli`, the command line, and `ucode-docopt` | 10 and 43 KiB |
| `luci-app-prometheus-exporter` | 54 KiB |

Take a 1.6 MB JFFS2 overlay (26 blocks of 64 KiB, LZMA), like a small access point's `rootfs_data`, empty apart from what these packages install. The base package, the LuCI app and three collectors (`-wifi`, `-hostapd_stations`, `-thermal`) take 296 KiB of it, apk's database included, and leave room for 1,092 KiB more. Upgrading them in place writes each new file beside the old one, and needs 20 KiB more. This was measured on QEMU's malta with an mtdram device. Your overlay's other files come on top, so check `df /overlay` first.

`ucode`, `ucode-mod-fs`, `-ubus`, `-uci` and `-rtnl` are in every 25.12 image with Wi-Fi. In the `-full` group, the programs that ethtool and qdisc run take more flash than all the group's collectors together: `ethtool` is 72 KiB, and `tc-tiny` and `kmod-sched-core` are 279 and 172 KiB.

**RAM.** uhttpd holds the handler and its collectors for as long as it runs. On the 24Kc, they take about 1.0 MB with the base collectors, or 1.5 MB with every collector of the `-full` group, on top of uhttpd's own memory. A scrape forks a process, which forks the collectors' child process. For the scrape's duration, they take about 2 MB more with the base collectors, or 4.5 MB with every collector. In a 64 MB QEMU guest with the base package, the `-full` group and the command line installed, the service served all 36 collectors. Its uhttpd held 1.7 MB (RssAnon), and the guest had 14.6 MB available.

**`memory_limit`.** Each of the exporter's processes may use `memory_limit` MB of data. The default, 0, means a quarter of the RAM, at most 64. On the 24Kc, the handler loads and a scrape succeeds with as little as 3 MB with the base collectors, or 5 MB with every collector (7 MB on a 64-bit CPU). A quarter of a 32 MB router's RAM, about 6 MB, is enough for either. A 64 MB router gets about 13 MB. See [memory_limit's floor](../explanation/performance.md#memory-floor).

## 2. Install the base package alone

```sh
apk update
apk add ucode-prometheus-exporter
```

The exporter serves without the command line or the LuCI app. `service prometheus-exporter check` checks the configuration without the command, and `uci` sets it. Add `ucode-prometheus-exporter-cli` only if you push metrics from cron or check a collector. Add `luci-app-prometheus-exporter` only if the device has LuCI.

## 3. Add only the collectors you need

Install collectors one by one rather than as a group. The `-full` group brings `ethtool` and `tc`, and the collectors that cost the most on a slow CPU. [What each collector costs](../explanation/performance.md#each-collector) gives each collector's memory at rest and cost per scrape, on the 24Kc and the A53. On a small router:

- **32 MB of RAM, 4 MB of flash**: the base collectors. Disable those you do not use (see [How to choose collectors](choose-collectors.md#disable-a-collector)). The exporter neither holds nor runs a disabled collector.
- **64 MB of RAM, 8 MB of flash**: add what the device has: `-wifi` on an access point, `-netstat`, `-openwrt`, `-wireguard`, and `-thermal` or `-hwmon` where it has sensors.
- **Leave out**:
    - `nat_traffic` on a router with a large connection table (5.6 s for 20,000 connections on the 24Kc)
    - `ethtool` (1.4 s on the benchmark's 17 ports on the 24Kc, plus its program's flash)
    - `dhcp_leases` where there are thousands of leases
    - `hostapd_stations` where `wifi` with `stations` does the job
    - `qdisc` without SQM
    - `unbound` unless you run Unbound. A scrape parses Unbound's statistics, which takes 30 ms on the 24Kc.

```sh
apk add ucode-prometheus-exporter-wifi ucode-prometheus-exporter-netstat
```

## 4. Check what it holds

```sh
service prometheus-exporter check
for p in $(pidof uhttpd); do grep -q handler.uc /proc/$p/cmdline && grep -E '^(RssAnon|VmData)' /proc/$p/status; done
free
```

`check` says the `memory_limit` the service runs under, and the collectors it serves. A collector that runs out of memory fails alone, with `COLLECTOR_KILLED`, and the exporter still serves the others. Raise `memory_limit`, or leave that collector out.

---

## See also

- [Performance on small routers](../explanation/performance.md): what a scrape costs, and what uhttpd holds.
- [Files and packages](../reference/files.md): what each package installs and depends on.
- [UCI configuration](../reference/uci-config.md): `memory_limit`.
