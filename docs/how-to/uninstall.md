# How to Remove the Exporter

## Remove a collector

=== "Browser (LuCI)"

    1. Open **System → Software**, and type the package's name in **Filter**, such as `ucode-prometheus-exporter-wifi`.
    2. On the **Installed** tab, press **Remove…** on its row, then **Remove** in the dialog.

=== "Terminal (SSH)"

    ```sh
    apk del ucode-prometheus-exporter-wifi
    ```

The service reloads without it. You cannot remove a collector of the base package this way: [disable it](choose-collectors.md#disable-a-collector) instead. A collector that a group installed stays while the group is installed. Remove the group, or keep the group and disable the collector.

## Remove the exporter

Remove the base package and everything that depends on it: the collector packages, the groups and the LuCI app:

```sh
apk del -r ucode-prometheus-exporter
```

The service stops, and rpcd no longer serves the `prometheus-exporter` ubus object. If you changed `/etc/config/prometheus-exporter`, apk keeps it. Remove it if you do not want it:

```sh
rm -f /etc/config/prometheus-exporter
```

What the service created at run time, `/var/run/prometheus-exporter/` and textfile's `/var/prometheus/`, is on tmpfs and disappears at the next reboot. The service's ubus ACL goes when the service stops.

The user and group `prometheus-exporter` stay, as OpenWrt keeps every package's user, but with nothing granted. When the package is removed, the service stops, and on stopping it:

- gives back the original group and mode of each config and `/proc` file it opened to that group, and
- takes the user out of every other group.

If Prometheus scrapes the device, remove it from the scrape configuration, or its target stays down.
