# How to Use the LuCI App

`luci-app-prometheus-exporter` sets up the exporter and shows how it does, from LuCI.

## Prerequisites

- `luci-app-prometheus-exporter` is installed, of the same version as the base package. After installing it, reload LuCI in the browser.

---

## Change the exporter's settings

1. Open **Services → Prometheus exporter**, tab **Exporter**.
2. Change the fields. A value the exporter would not take is marked as you type, with why.
3. **Save & Apply**.

To serve the LAN, pick its interface in **Listen on**. For basic auth, fill in **TLS certificate** and **TLS key**, then **Basic auth user** and **Basic auth password**: the password is hashed on Save, and never shown again. To keep the saved password, leave the field empty; to take basic auth away, empty the user.

## Switch a collector off or on

1. Open the **Collectors** tab.
2. Flip the collector's switch.
3. **Save & Apply**.

## Set a collector's options

1. On the **Collectors** tab, press **Edit** on the collector's row. The dialog shows its options, and for a collector that runs programs, the seconds they get; below, the configs it reads and what its jail mounts.
2. Change the fields, and press **Save**. The values are staged, not applied: they show among LuCI's unsaved changes.
3. **Save & Apply** on the page.

**Dismiss** drops what the dialog changed.

## See how the exporter does

Open **Status → Prometheus exporter**. It shows whether the service is enabled and runs, where it serves `/metrics`, and runs a scrape on the router to show each collector: **OK**, **Failed** with its error, **Nothing to observe** with why, or **Not run** when it is switched off. **Refresh** runs it again.

The scrape runs outside the jail. A collector that is OK here and failing in Prometheus lacks something in the jail: see [How to troubleshoot](troubleshoot.md).

---

## Let another user in

The app's ACL is `luci-app-prometheus-exporter`. A LuCI user granted it reads and writes `/etc/config/prometheus-exporter` and calls the exporter's ubus object, and nothing else; read access alone shows the pages without saving. See [LuCI app](../reference/luci.md#acl).
