# How to Publish Metrics from Scripts

The textfile collector serves the metrics of every `*.prom` file in a directory, `/var/prometheus` by default, as node_exporter's textfile collector does. A script on the device, run by cron or a hotplug event, writes what it knows there.

## Prerequisites

- `ucode-prometheus-exporter-textfile`, or the `-full` group, is installed.

---

## 1. Write the file

A file holds metrics in the Prometheus text format: `# HELP` and `# TYPE` lines, then samples. Write it to a temporary file in the same directory and rename it into place, so a scrape never reads half of it:

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

The temporary file's name must not end in `.prom`: the collector would read it.

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

The file's metrics are there, with `node_textfile_mtime_seconds{file="/var/prometheus/apk.prom"}`, when it was last written, and `node_textfile_scrape_error 0`.

---

## If a file is left out

A file that cannot be read, is not valid text format, gives a family another type than an earlier file did, repeats a series an earlier file has, or writes one of textfile's own families, is left out whole. `node_textfile_scrape_error` is then 1, and the log says which file and why:

```sh
logread -e prometheus-exporter | grep textfile
```

```
daemon.warn prometheus-exporter[1]: collector 'textfile': skipped /var/prometheus/apk.prom: EXPOSITION_INVALID (line 3: ...)
```

The collector itself still succeeds. Alert on `node_textfile_scrape_error == 1`, and on a `node_textfile_mtime_seconds` too old for how often the script runs.

## Use another directory

```sh
uci set prometheus-exporter.textfile=collector
uci set prometheus-exporter.textfile.directory=/var/lib/metrics
uci commit prometheus-exporter
service prometheus-exporter reload
```

The directory must be an absolute path, and not one every service shares, such as `/tmp` or `/var/run`: the jail would refuse to mount it. The service makes it when it starts, if it is not there. Keep it on tmpfs (`/var`, `/tmp`) unless the metrics must survive a reboot: a script writing to flash wears it.
