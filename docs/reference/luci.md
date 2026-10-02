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

The main section and the collector sections of `/etc/config/prometheus-exporter`, in four tabs: **General**, **HTTPS & login** and **Limits** hold the main section, **Collectors** the collectors. LuCI reopens the page on the tab last shown; at first, on **General**.

### General tab

| Field | Option | Notes |
| :--- | :--- | :--- |
| Enable | `enabled` | |
| Listen on | `listen_interface` | The interfaces of the ubus object's `interfaces`, and **Every address** (`*`). A saved interface netifd does not list is kept. |
| Port | `listen_port` | |
| Keep-alive | `http_keepalive` | |
| Compress | `compress` | |
| Leave out zero values | `omit_zero_values` | |

### HTTPS & login tab

The tab's description says basic auth needs HTTPS: the certificate and key first.

| Field | Option | Notes |
| :--- | :--- | :--- |
| TLS certificate | `cert` | No placeholder; the description names uhttpd's own files, `/etc/uhttpd.crt` and `/etc/uhttpd.key`. |
| TLS key | `key` | |
| Basic auth user | `auth_user` | |
| Basic auth password | `auth_password` | Never filled in. A password typed here is sent to `hash_password` on Save, and the hash it answers is saved; the password itself is never stored. Empty, the saved hash stays. |

The basic auth fields show without the TLS files too: LuCI unsets a field it hides, which would drop the user and the hash on Save.

### Limits tab

The tab's description says the limits keep a slow or broken collector from costing the whole scrape.

| Field | Option | Notes |
| :--- | :--- | :--- |
| Program timeout | `exec_timeout` | |
| Scrape timeout | `scrape_timeout` | |
| Collector budget | `collector_budget` | |

### Main section

- Every field is written, at its default too (`option enabled '1'`), but for the TLS files and basic auth, which are left out while empty. Emptying another field is refused.
- Emptying the user takes basic auth away, its hash with it.
- Basic auth without both TLS files, and a user without a password, are refused.

### Collectors tab

One row per collector the ubus object's `collectors` lists, sorted by title: its title with its help below, its package (**Base**, or the rest of the package's name after `ucode-prometheus-exporter-`, such as `wifi`, with the whole name on hover), a switch for `enabled`, and, for a collector with options, an **Edit** button. Above the table, how many are switched on (**12 of 45 collectors enabled**), as the switches are on the page. Collectors that are installed and do not load are listed above the form. When `collectors` cannot be called, the table says **The collectors could not be read.**

**Edit** opens a dialog with:

- a field per option of the collector, by its type, with its help and datatype;
- for a collector that runs programs, a field for the core's `timeout`, whose placeholder is the seconds it gets while it is empty: its own default, or `exec_timeout` as the Limits tab has it;
- read-only rows: **Reads** (the configs it reads), **Runs** (the programs it runs), **Jail mounts** (what the jail mounts for it) and, when there are any, **Jail problems**.

The first field has the focus when the dialog opens. The dialog's **Save** stages its values in uci, where they show among the unsaved changes; **Dismiss**, or Escape, drops them. Either way the focus goes back to the row's **Edit**. The page's **Save & Apply** applies them with the rest.

A login with read access alone opens the dialog too, with its fields and **Save** disabled.

A collector has a `config collector` section only while something differs from its defaults, its switch included. The section is added when a value first differs and removed once all are back. While it is there, it holds the switch and every option the collector declares, each written out; `timeout` only when it is set. A collector whose row did not change keeps its section as it was.

### Checks

Values are checked with the ubus object's `validate`, as the exporter reads them: the main section's while they are typed and again before Save, a dialog's while they are typed and again before it stages them. Nothing the exporter would refuse is saved or staged.

A tab with a field the exporter or LuCI would refuse shows how many on its title, LuCI's own badge, while another tab is shown.

A Save the exporter would refuse opens LuCI's **Save error** dialog, which lists each refused field and why, wherever the page is scrolled; the same list stays above the form until the values are fixed. Each field is named by its tab, as **HTTPS & login → Basic auth user**, and a collector's option as **Collectors → sampler retries**. The name is a link: it closes the dialog, shows the tab, and gives the field the focus, or the collector's **Edit**. A refused dialog says why inside the dialog.

### Without the ubus object

While the ubus object is not there (rpcd reloading, or the package being upgraded), the page says **The exporter's ubus object is not available (rpcd may be restarting). Reload in a moment.** and is read-only: no field can be changed and **Save** is disabled. An error of a call is shown by its message, never with LuCI's stack trace.

## Status → Prometheus exporter

The page runs each enabled collector once, a **test run**, when it opens and on **Refresh**, never on a timer. The test run is the ubus object's `status`: on the router, outside the service's jail and without its deadline, and it runs a quarantined collector all the same. So its results can differ from what Prometheus gets; the page says so above the tables.

| Part | Content |
| :--- | :--- |
| Banner | What needs attention, above the tables. See [Banners](#banners). |
| Service | Whether it runs, is enabled in the settings and starts at boot; where it serves `/metrics`, marked **(reachable from the router only)** on loopback; whether a scrape logs in, over HTTPS; whether it is compressed. |
| Collectors | The test run's counts, as **3 failed, 20 OK, 3 with nothing to observe, 0 off.**, then a row per installed collector. See [Collectors](#collectors). |

### Banners

| Banner | When | Content |
| :--- | :--- | :--- |
| Error | The service is enabled and not running. | **The exporter is enabled but not running: Prometheus gets nothing.**, with buttons to **System → Startup** and **System log**. |
| Notice | The service is switched off in its settings, and not running. | That Prometheus gets nothing, with a button to **Services → Prometheus exporter**. |
| Warning | Collectors failed in the test run. | How many, by title: **3 collectors failed in the test run: …** |
| Notice | The service quarantined collectors. | How many, by title, and that a restart of the service tries them at once. |

### Collectors

| Column | Content |
| :--- | :--- |
| Collector | Its title and name. |
| Test run | How it did in the test run, in words: **OK**; **Failed**, with the error's detail, then its code, which links to [Error codes](error-codes.md), and its jail mounts folded away; *Nothing to observe*, in italics, with why; or *Not run: switched off*. |
| Duration | Its time in the test run. |
| Service's scrapes | What the service's own scrapes found of it, from the running instance's ledger (the ubus object's `service` of each collector): **Quarantined**, with when the service tries it again and why, and **Left out at the deadline**, in the service's last scrape or how many scrapes ago, within the last 10. Empty otherwise. |

The rows are grouped, in this order, and sorted by title within a group:

1. Failed in the test run.
2. Quarantined, or left out at the deadline lately, by the service.
3. OK.
4. Nothing to observe.
5. Not run.

An error code the page does not know is shown and linked all the same; an error without a code is shown as it is. Status never rests on colour alone: each state is in words. On a narrow screen, a theme that shows each cell's column heading shows it only over a cell with something in it.

Without the ubus object, the page says so, as the settings page does.

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
