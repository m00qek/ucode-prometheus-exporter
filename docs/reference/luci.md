# LuCI App

`luci-app-prometheus-exporter` adds two pages to LuCI. It depends on `luci-base`, and on the exporter's base package of the same release. It calls the [ubus object](ubus.md) that the base package serves.

---

## Pages

| Menu | Path | View |
| :--- | :--- | :--- |
| **Services → Prometheus exporter** | `admin/services/prometheus-exporter` | `prometheus-exporter/settings` |
| **Status → Prometheus exporter** | `admin/status/prometheus-exporter` | `prometheus-exporter/status` |

Both need the ACL `luci-app-prometheus-exporter` and the config `prometheus-exporter`.

Every string from the router (collector names and help, packages, interfaces, paths, errors) reaches the page as a text node. The page puts it either in an array of children of `E()`, or into a translated template piece by piece. It never uses `.format()`, whose `%s` puts text where markup may go. It never uses such a string as a form's title or description, which LuCI renders as markup. `make lint`'s `luci-dom-lint.sh` refuses the usual ways around this.

## Services → Prometheus exporter

This page edits the main section and the collector sections of `/etc/config/prometheus-exporter`, in four tabs. **General**, **HTTPS & login** and **Limits** hold the main section, and **Collectors** holds the collectors. LuCI reopens the page on the tab last shown, or on **General** the first time.

### General tab

| Field | Option | Notes |
| :--- | :--- | :--- |
| Enable | `enabled` | |
| Listen on | `listen_interface` | The interfaces of the ubus object's `interfaces`, and **Every address** (`*`). A saved interface that netifd does not list is kept. |
| Port | `listen_port` | |
| Keep-alive | `http_keepalive` | |
| Compress | `compress` | |
| Leave out zero values | `omit_zero_values` | |

### HTTPS & login tab

The tab's description says that basic auth needs HTTPS, so the certificate and key come first.

| Field | Option | Notes |
| :--- | :--- | :--- |
| TLS certificate | `cert` | No placeholder. The description says where the files may be: `/etc/ssl`, `/etc/acme` or `/etc/prometheus-exporter`, at most 64 KiB, or uhttpd's own files, `/etc/uhttpd.crt` and `/etc/uhttpd.key`. The field marks a path elsewhere as `validate` refuses it (`TLS_PATH`). It does the same for a file there that is not a regular file of that size, or whose links lead out (`TLS_FILE`). |
| TLS key | `key` | |
| Basic auth user | `auth_user` | |
| Basic auth password | `auth_password`, in `/etc/config/prometheus-exporter-auth` | Not a field of the form: Save, Save & Apply and Revert never touch it, and the page never reads the hash. The row says **Set** or **Not set**, as the ubus object's `password` answers. It has two buttons, which act at once. See [Basic auth password](#basic-auth-password). |

The basic auth fields show even without the TLS files, and the ubus object refuses them there. If the page hid them, LuCI would unset them (it unsets an option whose `depends` are not met), which would drop the user on Save and leave the hash unused.

#### Basic auth password

Like LuCI's own router password, this password is changed apart from the form, and at once:

- **Change password…** opens a dialog with **New password** and **Confirmation**, which must match: 1 to 256 bytes, without control characters.
    - Its **Change password** hands the password to the ubus object's `set_password`, which saves its hash and reloads the service.
    - **Cancel**, or Escape, changes nothing.
    - The dialog says that the password applies at once, and that every scraper must send it from then on.
    - The button needs **TLS certificate** and **TLS key** filled in, as basic auth does. Without them, the row says so.
- **Remove password** shows while a hash is saved. It asks for confirmation, then hands `set_password` an empty password, which removes the hash and reloads the service. It needs **Basic auth user** to be empty, because a user without a password is refused. So the row says to empty the user and Save & Apply first.

When either is done, a notification says so. When it fails, its dialog says why. The page never stores the password, and sends it only to `set_password`. A login that may only read sees whether a password is saved, with the buttons disabled.

### Limits tab

The tab's description says that the limits keep a slow or broken collector from costing the whole scrape.

| Field | Option | Notes |
| :--- | :--- | :--- |
| Scrape timeout | `scrape_timeout` | |
| Collector budget | `collector_budget` | |
| Program timeout | `exec_timeout` | |
| Sample limit | `max_samples` | |
| Reply sample limit | `max_scrape_samples` | |

### Main section

- The page writes every field, even at its default (`option enabled '1'`). The exceptions are the TLS files and basic auth, which it leaves out while they are empty. Emptying any other field is refused.
- Emptying the user turns basic auth off, and leaves the saved hash unused.
- Basic auth without both TLS files is refused, and so is a user without a password.

### Collectors tab

The tab has one row per collector that the ubus object's `collectors` lists, sorted by title. Each row shows:

- its title, with its help below;
- its package: **Base**, or the rest of the package's name after `ucode-prometheus-exporter-`, such as `wifi`, with the whole name on hover;
- a switch for `enabled`;
- an **Edit** button, for a collector with options.

Above the table, a count shows how many collectors are switched on, as the switches on the page stand: **12 of 45 collectors enabled**. Collectors that are installed but do not load are listed above the form. When `collectors` cannot be called, the table says **The collectors could not be read.**

**Edit** opens a dialog with:

- a field per option of the collector, by its type, labelled by the option's title, with its help and datatype;
- for a collector that runs programs, a field for the core's `timeout`, labelled **Program timeout**. Its placeholder is the seconds the collector gets while the field is empty: its own default, or `exec_timeout` as the Limits tab has it;
- read-only rows: **Reads** (the configs it reads), **Runs** (the programs it runs), **Jail mounts** (what the jail mounts for it) and, when there are any, **Jail problems**.

An option's label is the `title` the collector declares for it, shown as the collector gives it. Like the collector's own title and help, it comes from the router, so LuCI cannot translate it. LuCI labels the core's options in its own language: **Enabled**, **Program timeout**, **Budget** and **Sample limit**. A field's accessible name is its title and the collector's name, such as **Excluded devices option of the diskstats collector**.

The first field has the focus when the dialog opens. The dialog's **Save** stages its values in uci, where they show among the unsaved changes. **Dismiss**, or Escape, drops them. Either way, the focus goes back to the row's **Edit**. The page's **Save & Apply** applies the staged values with the rest.

A login with only read access can open the dialog too, with its fields and **Save** disabled.

A collector has a `config collector` section only while something differs from its defaults, its switch included. The page adds the section when a value first differs, and removes it once all values are back to their defaults. While the section is there, it holds the switch and every option the collector declares, each written out, and `timeout` only when it is set. A collector whose row did not change keeps its section as it was.

### Checks

The page checks values with the ubus object's `validate`, as the exporter reads them:

- the main section's values while they are typed, and again before Save;
- a dialog's values while they are typed, and again before the dialog stages them.

Nothing the exporter would refuse is saved or staged.

`validate` answers each refusal with a [code](uci-config.md#problems) and its arguments. The page turns each into a sentence of its own, in the user's language, that names the field by its title, not its option: **Port must be an integer from 1 to 65535, not 0**, **Basic auth user needs HTTPS: set TLS certificate and TLS key, or the password crosses the network in the clear**. A collector's option is named by the title the collector gives it, untranslated. For a code the page does not know, from a newer exporter, it shows the exporter's English `message` after the field's title.

While another tab is shown, a tab with fields the exporter or LuCI would refuse shows how many on its title, with LuCI's own badge.

A Save that the exporter would refuse opens LuCI's **Save error** dialog, wherever the page is scrolled. The dialog lists each refused field and why. The same list stays above the form until the values are fixed.

- Each field is named by its tab, such as **HTTPS & login → Basic auth user**.
- A collector's option is named by the collector's title and the option's, such as **Collectors → Disk I/O → Excluded devices**.
- The name is a link. It closes the dialog, shows the tab, and gives the focus to the field, or to the collector's **Edit**.

A refused collector dialog says why inside the dialog.

The browser checks the `regex` datatype as a JavaScript regular expression, which catches unbalanced brackets. The exporter compiles it as POSIX extended, so the object's `validate` has the last word.

The page's sentences for `validate`'s problem codes are its own translations of the English in `config/problems.uc`. A test holds the two to the same codes, so a new code goes into both in the same change.

### Without the ubus object

The ubus object may be missing while rpcd reloads or the package is being upgraded. The page then says **The exporter's ubus object is not available (rpcd may be restarting). Reload in a moment.** and is read-only: no field can be changed, and **Save** is disabled. The page shows a failed call by its message, never with LuCI's stack trace.

The page takes the object as missing on:

- uhttpd's JSON-RPC errors -32000 (no such object) and -32002 (access cannot be checked: rpcd, which holds the sessions, is not answering);
- ubus's codes 3 and 4 (method or object not found).

## Status → Prometheus exporter

The page runs each enabled collector once, a **test run**, when it opens and on **Refresh**, never on a timer. The test run is the ubus object's [`status`](ubus.md#status): a scrape of its own on the router, apart from the service's scrapes, which runs a quarantined collector all the same. So its results can differ from what Prometheus gets, and the page says so above the tables.

| Part | Content |
| :--- | :--- |
| Banner | What needs attention, above the tables. See [Banners](#banners). |
| Service | Whether it runs, is enabled in the settings, and starts at boot; where it serves `/metrics`, marked **(reachable from the router only)** on loopback; whether a scrape logs in, over HTTPS; whether the reply is compressed. |
| Collectors | The test run's counts, as **3 failed, 20 OK, 3 with nothing to observe, 0 off.**, then a row per installed collector. See [Collectors](#collectors). |

### Banners

| Banner | When | Content |
| :--- | :--- | :--- |
| Error | The service is enabled and not running. | **The exporter is enabled but not running: Prometheus gets nothing.**, with buttons to **System → Startup** and **System log**. |
| Notice | The service is switched off in its settings, and not running. | That Prometheus gets nothing, with a button to **Services → Prometheus exporter**. |
| Warning | Collectors failed in the test run. | How many, by title: **3 collectors failed in the test run: …** |
| Notice | The service quarantined collectors. | How many, by title, and that restarting the service tries them at once. |

### Collectors

| Column | Content |
| :--- | :--- |
| Collector | Its title and name. |
| Test run | How it did in the test run, in words: **OK**; **Failed**, with the error's detail, then its code, which links to [Error codes](error-codes.md), and its jail mounts folded away; *Nothing to observe*, in italics, with why; or *Not run: switched off*. |
| Duration | Its time in the test run. |
| Service's scrapes | What the service's own scrapes found of it, from the running instance's ledger (the ubus object's `service` of each collector). **Quarantined**, with when the service tries it again and why. **Left out at the deadline**, in the service's last scrape or how many scrapes ago, within the last 10. Empty otherwise. |

The rows are grouped in this order, and sorted by title within a group:

1. Failed in the test run.
2. Quarantined, or recently left out at the deadline, by the service.
3. OK.
4. Nothing to observe.
5. Not run.

An error code the page does not know is still shown and linked. An error without a code is shown as it is. Status never rests on colour alone: each state is in words. On a narrow screen, a theme that shows each cell's column heading shows it only over a cell that has content.

Without the ubus object, the page says so, as the settings page does.

## ACL

`/usr/share/rpcd/acl.d/luci-app-prometheus-exporter.json`:

| Access | ubus methods of `prometheus-exporter` | uci |
| :--- | :--- | :--- |
| read | `collectors`, `interfaces`, `password`, `status`, `validate` | `prometheus-exporter` |
| write | `set_password` | `prometheus-exporter` |

It grants nothing else. In particular, it grants neither read nor write on `/etc/config/prometheus-exporter-auth`, which holds the hash. Only a login that may write gets `set_password`, which writes the hash.

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
