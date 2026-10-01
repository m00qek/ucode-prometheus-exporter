# How to Use the Lab

The lab is OpenWrt under procd in a privileged container, left running, with the built packages, every collector and the LuCI app installed: a device to try things on.

## Start it

```bash
make lab
```

It builds the packages, boots OpenWrt and installs them. When it is up:

```
The lab runs, as container ucode-prometheus-exporter-lab:
  LuCI      http://127.0.0.1:8080/  (root, no password)
  /metrics  http://127.0.0.1:9100/metrics
  a shell   docker exec -it ucode-prometheus-exporter-lab ash
  stop it   make lab-down
```

If a port is taken, or another checkout runs a lab, give yours its own name and ports:

```bash
make lab LAB_NAME=my-lab LAB_LUCI_PORT=18080 LAB_METRICS_PORT=19100
```

## Try a change

Edit the code, then run `make lab` again: it rebuilds the packages and starts the lab afresh, so nothing you changed by hand in it survives.

## Look inside

```bash
docker exec -it ucode-prometheus-exporter-lab ash
```

```sh
service prometheus-exporter check
logread -e prometheus-exporter
ubus call prometheus-exporter status
```

## Stop it

```bash
make lab-down
```

With `LAB_NAME` too, if you gave one.

---

## What is different from a device

- `lan` is the container's `eth0`, with the address docker gave it, and no bridge.
- The firewall, mwan3 and chronyd do not start: fw4 would reject what docker forwards, mwan3 would rewrite the routing, and chronyd would steer the clock, which a privileged container shares with its host. Do not start chronyd there.
- The exporter listens on every address (`listen_interface '*'`), which docker's published port needs.
- Unbound listens on port 5353, with its control socket where the unbound collector looks.
- textfile has a file to read, `/var/prometheus/lab.prom`.
- ubnt-manager's sample radio is removed, or ssh to it would cost each scrape its 5 seconds.

The boot is `devenv/services/lab/boot.sh`, the setup `devenv/services/lab/setup.sh`.
