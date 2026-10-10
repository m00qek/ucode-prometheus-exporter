# How to Remove the Exporter

## Remove a collector

```sh
apk del ucode-prometheus-exporter-wifi
```

The service reloads without it. A collector of the base package cannot be removed this way: [disable it](choose-collectors.md#disable-a-collector) instead. A collector a group installed stays while the group is installed: remove the group, or keep the group and disable the collector.

## Remove the exporter

Remove the base package and everything that depends on it, the collector packages, the groups and the LuCI app with it:

```sh
apk del -r ucode-prometheus-exporter
```

The service stops, and rpcd no longer serves the `prometheus-exporter` ubus object. If you changed `/etc/config/prometheus-exporter`, apk keeps it; remove it if you do not want it:

```sh
rm -f /etc/config/prometheus-exporter
```

What the service made at run time, `/var/run/prometheus-exporter/` and textfile's `/var/prometheus/`, is on tmpfs and goes at the next reboot; its ubus ACL goes when it stops. The user and group `prometheus-exporter` stay, as OpenWrt keeps every package's, with nothing granted: removing the package stops the service, which gives each config and `/proc` file it opened to that group its group and mode back, and takes the user out of every other group.

If Prometheus scrapes the device, take it out of the scrape configuration, or its target stays down.
