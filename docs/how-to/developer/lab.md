# How to Use the Lab

The lab is a device to try things on. It is OpenWrt under procd in a privileged container, left running, with the built packages installed: every collector and the LuCI app.

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

Edit the code, then run `make lab` again. It rebuilds the packages and starts the lab afresh, so anything you changed by hand in the lab is lost.

## Look inside

```bash
docker exec -it ucode-prometheus-exporter-lab ash
```

```sh
service prometheus-exporter check
logread -e prometheus-exporter
ubus call prometheus-exporter status
```

## Watch it with Prometheus, Grafana and Perses

```bash
make monitoring-lab
```

It starts, each from its official image and unprivileged:

- a Prometheus that scrapes the lab every 5 seconds, with the rules of `monitoring/prometheus/`
- a Grafana with the dashboards of `monitoring/grafana/`
- a Perses with the dashboards of `monitoring/perses/`

After `MONITORING_WAIT` seconds of scrapes (3 minutes), it runs every panel's queries through Grafana and through Perses. It fails on a query that errs, or that has no data where the lab has some. Then it screenshots each dashboard:

```
Monitoring the lab ucode-prometheus-exporter-lab:
  Prometheus  http://127.0.0.1:9090/alerts
  Grafana     http://127.0.0.1:3000/dashboards  (no login)
  Perses      http://127.0.0.1:8081/projects/openwrt
  results     bin/monitoring/report.txt, bin/monitoring/screenshots/
  stop it     make monitoring-lab-down
```

The screenshots in [How to monitor a router with the bundled dashboards and alerts](../dashboards-and-alerts.md) are these, taken with `MONITORING_WAIT=960`, so that the last 15 minutes they show all hold lab data. Give the same `LAB_NAME` as the lab's, and other ports if those are taken: `make monitoring-lab LAB_NAME=my-lab GRAFANA_PORT=13000`.

## Stop it

```bash
make monitoring-lab-down
make lab-down
```

With `LAB_NAME` too, if you gave one.

---

## What is different from a device

- `lan` is the container's `eth0`, with the address docker gave it, and no bridge.
- The firewall, mwan3 and chronyd do not start:
    - fw4 would reject what docker forwards.
    - mwan3 would rewrite the routing.
    - chronyd would steer the clock, which a privileged container shares with its host. Do not start chronyd there.
- The exporter listens on every address (`listen_interface '*'`), which docker's published port needs.
- Unbound listens on port 5353, with its control socket where the unbound collector looks.
- textfile has a file to read, `/var/prometheus/lab.prom`.
- ubnt-manager's sample radio is removed. Otherwise, ssh to it would cost each scrape 5 seconds.

The boot is in `devenv/services/lab/boot.sh`, and the setup in `devenv/services/lab/setup.sh`.
