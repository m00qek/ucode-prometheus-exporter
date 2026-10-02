# LuCI App

`luci-app-prometheus-exporter` adds two pages to LuCI. It depends on `luci-base` and on the exporter's base package of the same release, and calls the [ubus object](ubus.md) the base package serves.

---

## Pages

| Menu | Path | View |
| :--- | :--- | :--- |
| **Services → Prometheus exporter** | `admin/services/prometheus-exporter` | `prometheus-exporter/settings` |
| **Status → Prometheus exporter** | `admin/status/prometheus-exporter` | `prometheus-exporter/status` |

Both need the ACL `luci-app-prometheus-exporter` and the config `prometheus-exporter`.

## Services → Prometheus exporter

The main section and the collector sections of `/etc/config/prometheus-exporter`, in two tabs.

### Exporter tab

| Field | Option | Notes |
| :--- | :--- | :--- |
| Enable | `enabled` | |
| Listen on | `listen_interface` | The interfaces of the ubus object's `interfaces`, and **Every address** (`*`). A saved interface netifd does not list is kept. |
| Port | `listen_port` | |
| Keep-alive | `http_keepalive` | |
| TLS certificate | `cert` | No placeholder; the description names uhttpd's own files, `/etc/uhttpd.crt` and `/etc/uhttpd.key`. |
| TLS key | `key` | |
| Basic auth user | `auth_user` | The description says basic auth needs the TLS certificate and key first. |
| Basic auth password | `auth_password` | Never filled in. A password typed here is sent to `hash_password` on Save, and the hash it answers is saved; the password itself is never stored. Empty, the saved hash stays. |
| Compress | `compress` | |
| Leave out zero values | `omit_zero_values` | |
| Program timeout | `exec_timeout` | |
| Scrape timeout | `scrape_timeout` | |
| Collector budget | `collector_budget` | |

- Every field is written, at its default too (`option enabled '1'`), but for the TLS files and basic auth, which are left out while empty. Emptying another field is refused.
- Emptying the user takes basic auth away, its hash with it.
- Basic auth without both TLS files, and a user without a password, are refused.

### Collectors tab

One row per collector the ubus object's `collectors` lists, sorted by title: its title with its help below, its package (**Base**, or the rest of the package's name after `ucode-prometheus-exporter-`, such as `wifi`, with the whole name on hover), a switch for `enabled`, and, for a collector with options, an **Edit** button. Above the table, how many are switched on (**12 of 45 collectors enabled**), as the switches are on the page. Collectors that are installed and do not load are listed above the form. When `collectors` cannot be called, the table says **The collectors could not be read.**

**Edit** opens a dialog with:

- a field per option of the collector, by its type, with its help and datatype;
- for a collector that runs programs, a field for the core's `timeout`, whose placeholder is the seconds it gets while it is empty: its own default, or `exec_timeout` as the Exporter tab has it;
- read-only rows: **Reads** (the configs it reads), **Runs** (the programs it runs), **Jail mounts** (what the jail mounts for it) and, when there are any, **Jail problems**.

The first field has the focus when the dialog opens. The dialog's **Save** stages its values in uci, where they show among the unsaved changes; **Dismiss**, or Escape, drops them. Either way the focus goes back to the row's **Edit**. The page's **Save & Apply** applies them with the rest.

A login with read access alone opens the dialog too, with its fields and **Save** disabled.

A collector has a `config collector` section only while something differs from its defaults, its switch included. The section is added when a value first differs and removed once all are back. While it is there, it holds the switch and every option the collector declares, each written out; `timeout` only when it is set. A collector whose row did not change keeps its section as it was.

### Checks

Values are checked with the ubus object's `validate`, as the exporter reads them: the Exporter tab's while they are typed and again before Save, a dialog's while they are typed and again before it stages them. Nothing the exporter would refuse is saved or staged.

A Save the exporter would refuse opens LuCI's **Save error** dialog, which lists each refused field and why, wherever the page is scrolled; the same list stays above the form until the values are fixed. A refused dialog says why inside the dialog.

### Without the ubus object

While the ubus object is not there (rpcd reloading, or the package being upgraded), the page says **The exporter's ubus object is not available (rpcd may be restarting). Reload in a moment.** and is read-only: no field can be changed and **Save** is disabled. An error of a call is shown by its message, never with LuCI's stack trace.

## Status → Prometheus exporter

| Part | Content |
| :--- | :--- |
| Service | Whether it is enabled in the settings, starts at boot and runs; where it serves `/metrics`, marked **(reachable from the router only)** on loopback; whether a scrape logs in, over HTTPS; whether it is compressed. |
| Collectors | Each collector's state in the page's scrape, **OK**, **Failed**, **Nothing to observe** (with why) or **Not run** (disabled); its duration; its error; what the jail mounts for it; and, in the **Service** column, what the service's own scrapes found of it: **Quarantined** (with when it is tried again, and why) and **Left out at the deadline** (in the last scrape, or how many scrapes ago, within the last 10). |

The scrape is the ubus object's `status`, run on the router outside the jail, when the page opens and on **Refresh**, never on a timer; it runs a quarantined collector all the same. The **Service** column is the ubus object's `service` of each collector, from the running instance's ledger. Without the ubus object, the page says so, as the settings page does.

## ACL

`/usr/share/rpcd/acl.d/luci-app-prometheus-exporter.json`:

| Access | ubus methods of `prometheus-exporter` | uci |
| :--- | :--- | :--- |
| read | `collectors`, `interfaces`, `status`, `validate` | `prometheus-exporter` |
| write | `hash_password` | `prometheus-exporter` |

Nothing else.

## Files

| File | Content |
| :--- | :--- |
| `/www/luci-static/resources/view/prometheus-exporter/settings.js` | Services → Prometheus exporter. |
| `/www/luci-static/resources/view/prometheus-exporter/status.js` | Status → Prometheus exporter. |
| `/www/luci-static/resources/prometheus-exporter.js` | What both pages share. |
| `/usr/share/luci/menu.d/luci-app-prometheus-exporter.json` | The menu entries. |
| `/usr/share/rpcd/acl.d/luci-app-prometheus-exporter.json` | The ACL. |

The translation template is `luci/po/templates/prometheus-exporter.pot` in the source tree.

## See also

- [How to use the LuCI app](../how-to/luci.md)
