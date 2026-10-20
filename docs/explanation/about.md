# About the Exporter

ucode-prometheus-exporter serves the metrics of an OpenWrt device to Prometheus: its CPU, memory, network devices and connections, and the services a router runs, from Wi-Fi to WireGuard to DNS. It is written in ucode, OpenWrt's own scripting language, and served by uhttpd, the web server every OpenWrt image already has. This page is about where it comes from, and why it is a rewrite rather than a patch.

---

## Two exporters before it

OpenWrt's packages feed has had two Prometheus exporters, both Apache-2.0.

`prometheus-node-exporter-lua` came first, in 2017. Christian Simon added it; Etienne Champetier maintains it, and split its single script into the collectors it has today. Over the years contributors added collectors for nearly everything a router does: Wi-Fi stations, hostapd, DSL modems, PoE switches, mesh daemons, mwan3, ModemManager, Ubiquiti radios, Unbound.

`prometheus-node-exporter-ucode` followed in 2022, by Andre Heider, who maintains it. It is the same idea in ucode, which OpenWrt had by then made its language of choice: LuCI's backend and the firewall, fw4, are ucode, and rpcd takes plugins in it. It has the core collectors and a handful of extras, and needs no Lua.

Between them, the ground was covered twice and unevenly: most collectors existed in Lua only, a few in ucode only, and some in both with different names. A device that wanted the Lua exporter's breadth needed a Lua runtime, which an image built around ucode otherwise does without.

## Why a rewrite

This exporter ports the Lua exporter's collectors alongside the ucode one's, so every collector either exporter had is here, in ucode. Writing them anew, rather than translating them line by line, let every collector take the same shape. That shape is built for three things a router asks of code that runs on it: to touch only what it must, to be tested before it gets there, and to be fast on a MIPS CPU.

- **Each collector says what it touches.** A collector declares the capabilities it needs, the configs it reads and the programs it runs, and gets those and nothing else. The service builds its jail from those declarations: see [About the security model](security.md).
- **Everything is tested off the device.** Only one module touches the system, and the tests hand collectors fakes of it, fed with what real devices answered. A collector is tested on the captures of real routers before it ever runs on one.
- **It is fast where it matters.** A typical router's full scrape takes about 2.6 seconds on a MIPS CPU of 500 MIPS, the class of an MT7621. See [Performance on small routers](performance.md).
- **It says what it cannot observe.** A device without radios is not failing to read its radios. See [About nothing to observe](nothing-to-observe.md).
- **The metric names are node_exporter's.** Dashboards made for node_exporter work as they are. See [About metric names](metric-names.md).

The names are the change that costs the most: queries made for either feed exporter break. A rewrite is the time to pay that once, rather than have every later version carry two sets of names.

## Why not node_exporter itself

The Prometheus node_exporter runs on Linux, and some run it on OpenWrt. But it is a Go binary of several megabytes, a lot on a router with 16 MB of flash. And it knows nothing of what makes a device an OpenWrt router: netifd's interfaces, hostapd, ubus, uci. This exporter takes node_exporter's names, so it fits the same dashboards, and adds what only OpenWrt has. Its base package takes about 120 KiB of flash (264 KiB installed), and an image with LuCI mostly has what it depends on, ucode and uhttpd, already.

## Replacing, not sitting beside

It installs under names of its own, `ucode-prometheus-exporter` and the `prometheus-exporter` service. It conflicts with both feed exporters, since they all want port 9100 and uhttpd's `/metrics`. Installed where one of them was, it takes over that one's settings. See [How to move from the feed's exporters](../how-to/migrate-from-feed.md).

## Credits

The collectors port those of the two feed packages: [`prometheus-node-exporter-ucode`](https://github.com/openwrt/packages/tree/master/utils/prometheus-node-exporter-ucode), by Andre Heider and contributors, and [`prometheus-node-exporter-lua`](https://github.com/openwrt/packages/tree/master/utils/prometheus-node-exporter-lua), by Jeff Schornick, Kevin Lyda, Christian Simon, Etienne Champetier and contributors. `NOTICE` credits each collector's upstream authors.

Metric names and help texts follow the Prometheus [node_exporter](https://github.com/prometheus/node_exporter) and, for Unbound, WireGuard and chrony, [unbound_exporter](https://github.com/letsencrypt/unbound_exporter), [prometheus_wireguard_exporter](https://github.com/MindFlavor/prometheus_wireguard_exporter) and [chrony_exporter](https://github.com/SuperQ/chrony_exporter). Tests run on [utest](https://github.com/m00qek/utest).
