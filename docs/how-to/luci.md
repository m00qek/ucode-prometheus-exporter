# How to Use the LuCI App

`luci-app-prometheus-exporter` sets up the exporter and shows how it does, from LuCI.

## Prerequisites

- `luci-app-prometheus-exporter` is installed, of the same version as the base package. After installing it, reload LuCI in the browser.

---

## Change the exporter's settings

1. Open **Services → Prometheus exporter**, tab **Exporter**.
2. Change the fields. A value the exporter would not take is marked as you type, with why.
3. **Save & Apply**. If the exporter would refuse a value, nothing is saved: a **Save error** dialog lists what and why. **Dismiss** it, fix the fields, and save again.

To serve the LAN, pick its interface in **Listen on**. Basic auth needs HTTPS: fill in **TLS certificate** and **TLS key** first, then **Basic auth user** and **Basic auth password**. The password is saved as a hash on Save; the password itself is never stored. To keep the saved password, leave the field empty; to take basic auth away, empty the user.

## Switch a collector off or on

1. Open the **Collectors** tab. The collectors are listed by title; above them, how many are switched on.
2. Untick the collector to stop serving its metrics, or tick it to serve them again.
3. **Save & Apply**.

## Set a collector's options

1. On the **Collectors** tab, press **Edit** on the collector's row. The dialog shows its options, and for a collector that runs programs, the seconds they get; below, what it reads and runs, and what its jail mounts.
2. Change the fields, and press **Save**. The values are staged, not applied: they show among LuCI's unsaved changes.
3. **Save & Apply** on the page.

**Dismiss**, or Escape, drops what the dialog changed.

## See how the exporter does

Open **Status → Prometheus exporter**. It shows whether the service is enabled and runs, where it serves `/metrics`, and runs a scrape on the router to show each collector: **OK**, **Failed** with its error, **Nothing to observe** with why, or **Not run** when it is switched off. **Refresh** runs it again.

The scrape runs outside the jail. A collector that is OK here and failing in Prometheus lacks something in the jail: see [How to troubleshoot](troubleshoot.md).

## If a page says the ubus object is not available

The pages talk to the exporter through its ubus object, which rpcd serves. While rpcd reloads, or the package is being upgraded, it is not there: the pages say so, and the settings are read-only. Reload the page in a moment. If it stays, check that rpcd runs and loaded the object: `ubus list prometheus-exporter`.

---

## Let another user in

The app's ACL is `luci-app-prometheus-exporter`. A LuCI user granted it reads and writes `/etc/config/prometheus-exporter` and calls the exporter's ubus object, and nothing else; read access alone shows the pages, and a collector's options under **Edit**, without saving. See [LuCI app](../reference/luci.md#acl).
