# LuCI App

`luci-app-prometheus-exporter` adds two pages to LuCI. It depends on `luci-base` and on the exporter's base package of the same release, and calls the [ubus object](ubus.md) the base package serves.

---

## Pages

| Menu | Path | View |
| :--- | :--- | :--- |
| **Services → Prometheus exporter** | `admin/services/prometheus-exporter` | `prometheus-exporter/settings` |
| **Status → Prometheus exporter** | `admin/status/prometheus-exporter` | `prometheus-exporter/status` |

Both need the ACL `luci-app-prometheus-exporter` and the config `prometheus-exporter`.

Every string from the router (collector names and help, packages, interfaces, paths, errors) reaches the page as a text node: inside an array of children of `E()`, or filled into a translated template piece by piece, never with `.format()`, whose `%s` puts text where markup may go, and never as a form's title or description, which LuCI renders as markup. `make lint`'s `luci-dom-lint.sh` refuses the usual ways round it.

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
| TLS certificate | `cert` | No placeholder; the description names where the files may be, `/etc/ssl`, `/etc/acme` or `/etc/prometheus-exporter`, at most 64 KiB, and uhttpd's own files, `/etc/uhttpd.crt` and `/etc/uhttpd.key`. A path elsewhere, or a file there that is not a regular one of that size or whose links lead out, is marked as `validate` refuses it (`TLS_PATH`, `TLS_FILE`). |
| TLS key | `key` | |
| Basic auth user | `auth_user` | |
| Basic auth password | `auth_password`, in `/etc/config/prometheus-exporter-auth` | No field of the form: Save, Save & Apply and Revert never touch it, and the page never reads the hash. The row says **Set** or **Not set**, as the ubus object's `password` answers, and has two buttons, which act at once. See [Basic auth password](#basic-auth-password). |

The basic auth fields show without the TLS files too: LuCI unsets a field it hides, which would drop the user on Save.

#### Basic auth password

As LuCI's own router password, the password is changed apart from the form, and at once:

- **Change password…** opens a dialog: **New password**, and **Confirmation**, which must match, 1 to 256 bytes without control characters. Its **Change password** hands the password to the ubus object's `set_password`, which saves its hash and reloads the service; **Cancel**, or Escape, changes nothing. The dialog says that the password applies at once, and that every scraper must send it from then on. The button needs **TLS certificate** and **TLS key** filled in, as basic auth does; without them the row says so.
- **Remove password**, shown while a hash is saved, asks, then hands `set_password` an empty password, which removes the hash and reloads the service. It needs **Basic auth user** empty: a user without a password is refused, so the row says to empty the user and Save & Apply first.

Either says in a notification that it was done, or in its dialog why it failed. The password itself is never stored, nor sent but to `set_password`. A login that may only read sees whether a password is saved, its buttons disabled.

Basic auth's fields are shown without TLS too, and the object refuses them there: LuCI unsets an option whose `depends` are not met, which would drop the user and leave the hash unused.

### Limits tab

The tab's description says the limits keep a slow or broken collector from costing the whole scrape.

| Field | Option | Notes |
| :--- | :--- | :--- |
| Scrape timeout | `scrape_timeout` | |
| Collector budget | `collector_budget` | |
| Program timeout | `exec_timeout` | |
| Sample limit | `max_samples` | |
| Reply sample limit | `max_scrape_samples` | |

### Main section

- Every field is written, at its default too (`option enabled '1'`), but for the TLS files and basic auth, which are left out while empty. Emptying another field is refused.
- Emptying the user takes basic auth away, the saved hash left unused.
- Basic auth without both TLS files, and a user without a password, are refused.

### Collectors tab

One row per collector the ubus object's `collectors` lists, sorted by title: its title with its help below, its package (**Base**, or the rest of the package's name after `ucode-prometheus-exporter-`, such as `wifi`, with the whole name on hover), a switch for `enabled`, and, for a collector with options, an **Edit** button. Above the table, how many are switched on (**12 of 45 collectors enabled**), as the switches are on the page. Collectors that are installed and do not load are listed above the form. When `collectors` cannot be called, the table says **The collectors could not be read.**

**Edit** opens a dialog with:

- a field per option of the collector, by its type, labelled by the option's title, with its help and datatype;
- for a collector that runs programs, a field for the core's `timeout`, labelled **Program timeout**, whose placeholder is the seconds it gets while it is empty: its own default, or `exec_timeout` as the Limits tab has it;
- read-only rows: **Reads** (the configs it reads), **Runs** (the programs it runs), **Jail mounts** (what the jail mounts for it) and, when there are any, **Jail problems**.

An option's title is the collector's `title` of it, shown as the collector gives it: it comes from the router, as the collector's own title and help do, so LuCI cannot translate it. The core's options are labelled by LuCI, in its language: **Enabled**, **Program timeout**, **Budget** and **Sample limit**. A field's accessible name is its title and the collector's name, as **Excluded devices option of the diskstats collector**.

The first field has the focus when the dialog opens. The dialog's **Save** stages its values in uci, where they show among the unsaved changes; **Dismiss**, or Escape, drops them. Either way the focus goes back to the row's **Edit**. The page's **Save & Apply** applies them with the rest.

A login with read access alone opens the dialog too, with its fields and **Save** disabled.

A collector has a `config collector` section only while something differs from its defaults, its switch included. The section is added when a value first differs and removed once all are back. While it is there, it holds the switch and every option the collector declares, each written out; `timeout` only when it is set. A collector whose row did not change keeps its section as it was.

### Checks

Values are checked with the ubus object's `validate`, as the exporter reads them: the main section's while they are typed and again before Save, a dialog's while they are typed and again before it stages them. Nothing the exporter would refuse is saved or staged.

`validate` answers what it refuses by a [code](uci-config.md#problems) and its arguments, and the page says each in a sentence of its own, in the user's language, that names the field by its title, not its option: **Port must be an integer from 1 to 65535, not 0**, **Basic auth user needs HTTPS: set TLS certificate and TLS key, or the password crosses the network in the clear**. A collector's option is named by the title the collector gives it, untranslated. A code the page does not know, of a newer exporter, is shown by the exporter's English, `message`, after the field's title.

A tab with a field the exporter or LuCI would refuse shows how many on its title, LuCI's own badge, while another tab is shown.

A Save the exporter would refuse opens LuCI's **Save error** dialog, which lists each refused field and why, wherever the page is scrolled; the same list stays above the form until the values are fixed. Each field is named by its tab, as **HTTPS & login → Basic auth user**, and a collector's option by the collector's title and the option's, as **Collectors → Disk I/O → Excluded devices**. The name is a link: it closes the dialog, shows the tab, and gives the field the focus, or the collector's **Edit**. A refused dialog says why inside the dialog.

The `regex` datatype is checked in the browser as a JavaScript regular expression, which catches unbalanced brackets; the exporter compiles it as POSIX extended, so the object's `validate` has the last word. The page's sentences for `validate`'s problem codes are its own translations of `config/problems.uc`'s English, and a test holds the two to the same codes: a new code goes into both in the same change.

### Without the ubus object

While the ubus object is not there (rpcd reloading, or the package being upgraded), the page says **The exporter's ubus object is not available (rpcd may be restarting). Reload in a moment.** and is read-only: no field can be changed and **Save** is disabled. An error of a call is shown by its message, never with LuCI's stack trace.

The page takes the object as missing on uhttpd's JSON-RPC errors -32000 (no such object) and -32002 (access cannot be checked: rpcd, which holds the sessions, is not answering), and on ubus's codes 3 and 4 (method or object not found).

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
| read | `collectors`, `interfaces`, `password`, `status`, `validate` | `prometheus-exporter` |
| write | `set_password` | `prometheus-exporter` |

Nothing else: not `/etc/config/prometheus-exporter-auth`, which holds the hash, to read or to write. `set_password`, which writes it, is granted to a login that may write alone.

## Files

| File | Content |
| :--- | :--- |
| `/www/luci-static/resources/view/prometheus-exporter/settings.js` | Services → Prometheus exporter. |
| `/www/luci-static/resources/view/prometheus-exporter/status.js` | Status → Prometheus exporter. |
| `/www/luci-static/resources/prometheus-exporter.js` | What both pages share. |
| `/www/luci-static/resources/prometheus-exporter/widgets.js` | The settings page's widgets: the listen interface's picker, basic auth's password and its dialogs, and the Collectors tab's table and its Edit dialog. |
| `/usr/share/luci/menu.d/luci-app-prometheus-exporter.json` | The menu entries. |
| `/usr/share/rpcd/acl.d/luci-app-prometheus-exporter.json` | The ACL. |

The translation template is `luci/po/templates/prometheus-exporter.pot` in the source tree.

## See also

- [How to use the LuCI app](../how-to/luci.md)
