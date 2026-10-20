# How to Publish Metrics from Scripts

The textfile collector serves the metrics of every `*.prom` file in a directory, `/var/prometheus` by default, as node_exporter's textfile collector does. A script on the device, run by cron or a hotplug event, writes its metrics there.

## Prerequisites

- `ucode-prometheus-exporter-textfile`, or the `-full` group, is installed.

---

## 1. Write the file

A file holds metrics in the Prometheus text format: `# HELP` and `# TYPE` lines, then samples. Write to a temporary file in the same directory, then rename it into place, so a scrape never reads half a file:

```sh
#!/bin/sh
# /usr/bin/apk-metrics: how many packages can be upgraded.
dir=/var/prometheus
tmp=$(mktemp "$dir/.apk.XXXXXX")
n=$(apk list --upgradable 2>/dev/null | wc -l)
cat >"$tmp" <<EOF
# HELP apk_upgradable_packages Packages with an upgrade available.
# TYPE apk_upgradable_packages gauge
apk_upgradable_packages $n
EOF
chmod 0644 "$tmp"
mv -f "$tmp" "$dir/apk.prom"
```

`mktemp` makes the file 0600, so only root can read it. The service reads it as its own user, `prometheus-exporter`, hence the `chmod`. The collector skips a file that only root can read, and logs it.

Some more rules for the file:

- The temporary file's name must not end in `.prom`, or the collector reads it.
- Write a regular file. The collector skips anything else (a FIFO, a device) without opening it, and counts it in `node_textfile_scrape_error`. So a pipe that nothing writes to cannot hold up a scrape.
- Give your metrics names of your own. If a file writes metrics that another collector also writes (`node_load1`, for example), the whole textfile collector fails with `FAMILY_CONFLICT`.

## 2. Run it

From cron, every hour:

```sh
chmod +x /usr/bin/apk-metrics
echo '0 * * * * /usr/bin/apk-metrics' >>/etc/crontabs/root
service cron restart
```

## 3. Check it

```sh
prometheus-exporter scrape textfile
```

The output has the file's metrics, plus `node_textfile_mtime_seconds{file="/var/prometheus/apk.prom"}`, the time the file was last written, and `node_textfile_scrape_error 0`.

---

## If a file is left out

The collector leaves out a whole file if it:

- cannot be read,
- is not valid text format,
- gives a family a different type than an earlier file did,
- repeats a series an earlier file has, or
- writes one of textfile's own families.

`node_textfile_scrape_error` is then 1, and the log says which file and why:

```sh
logread -e prometheus-exporter | grep textfile
```

```
daemon.warn prometheus-exporter[1]: collector 'textfile': skipped /var/prometheus/apk.prom: EXPOSITION_INVALID (line 3: ...)
```

The collector itself still succeeds. Alert on `node_textfile_scrape_error == 1`. Also alert when `node_textfile_mtime_seconds` is too old for how often the script runs.

## Use another directory

```sh
uci set prometheus-exporter.textfile=collector
uci set prometheus-exporter.textfile.directory=/var/lib/metrics
uci commit prometheus-exporter
service prometheus-exporter reload
```

The directory must be under `/var`, `/tmp` or `/etc/prometheus-exporter`, and must not be one that every service shares, such as `/var/run`. When the service starts, it creates the directory as root if it is missing, and mounts it in its jail. So it refuses any other directory, with `OWNED_DIRECTORY`.

Keep the directory on tmpfs (`/var`, `/tmp`). Only if the metrics must survive a reboot, put it under `/etc/prometheus-exporter`: a script that writes to flash wears it out.
