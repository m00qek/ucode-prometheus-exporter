# How to Use the LuCI App

`luci-app-prometheus-exporter` lets you set up the exporter from LuCI, and see how it is doing.

## Prerequisites

- `luci-app-prometheus-exporter` is installed, at the same version as the base package. After installing it, reload LuCI in the browser.

---

## Change the exporter's settings

1. Open **Services → Prometheus exporter**. The settings are on three tabs:
    - **General**: whether it runs, where it listens, keep-alive, compression and zero values;
    - **HTTPS & login**: the TLS certificate and key, and basic auth;
    - **Limits**: the seconds programs, a scrape and a collector get.
2. Change the fields. As you type, the form marks a value the exporter would not take, and says why. A tab with such fields shows how many in its title.
3. Press **Save & Apply**. If the exporter would refuse a value, nothing is saved. A **Save error** dialog lists each problem and why, with each field under its tab. Press a field's name to go to it, fix it, and save again.

To serve the LAN, pick its interface in **Listen on**, on **General**.

Basic auth needs HTTPS. On **HTTPS & login**, fill in **TLS certificate** and **TLS key** first, then **Basic auth user**, and press **Save & Apply**. The password is not a field of the form, and Save, Save & Apply and Revert do not touch it. As with LuCI's own router password, you change it separately, and the change applies at once.

## Change basic auth's password

1. On **HTTPS & login**, **Basic auth password** says whether a password is saved: **Set** or **Not set**. Press **Change password…**. It needs **TLS certificate** and **TLS key** filled in.
2. Type the new password in **New password** and again in **Confirmation**, and press **Change password**.
3. The hash is saved at once, and the exporter reloads with it. Give every scraper the new password. The password itself is never stored, and the page never sees the hash.

To turn basic auth off, empty **Basic auth user** and press **Save & Apply**. A saved password is then unused. Once the user is empty, **Remove password** also removes the password. Like a change, the removal applies at once.

## Switch a collector off or on

1. Open the **Collectors** tab. It lists the collectors by title, and above them, how many are switched on.
2. Untick the collector to stop serving its metrics, or tick it to serve them again.
3. Press **Save & Apply**.

## Set a collector's options

1. On the **Collectors** tab, press **Edit** on the collector's row. The dialog shows the collector's options, and, if it runs programs, the seconds they get. Below them, it shows what the collector reads and runs, and what its jail mounts.
2. Change the fields, and press **Save**. The values are staged, not applied: they show among LuCI's unsaved changes.
3. Press **Save & Apply** on the page.

**Dismiss**, or Escape, drops the dialog's changes.

## See how the exporter does

1. Open **Status → Prometheus exporter**. The page runs each enabled collector once on the router, as a test run. It shows:
    - A banner above the tables, for what needs attention: the exporter is enabled but not running, collectors failed, or the service quarantined collectors.
    - Whether the service runs, is enabled and starts at boot, and where it serves `/metrics`.
    - Each collector, failed ones first. **Test run** says **OK**, **Failed** with why and its error code, *Nothing to observe* with why, or *Not run: switched off*. **Service's scrapes** says whether the service quarantined the collector, or its deadline left the collector out lately.
2. If the banner says the exporter is enabled but not running, press **System → Startup** to start it, or **System log** to see why it stopped.
3. If a collector failed, its error code links to what the code means. See [How to troubleshoot](troubleshoot.md).
4. **Refresh** runs the test run again.

The test run is separate from the service's scrapes. It runs outside the service's jail and without the scrape deadline. If a collector is OK in **Test run** but fails in Prometheus, it lacks something in the jail, or the service quarantined it or left it out, as **Service's scrapes** says. See [How to troubleshoot](troubleshoot.md).

## If a page says the ubus object is not available

The pages talk to the exporter through its ubus object, which rpcd serves. The object is missing while rpcd reloads, or while the package is being upgraded. The pages then say so, and the settings are read-only. Reload the page in a moment. If the message stays, check that rpcd runs and loaded the object: `ubus list prometheus-exporter`.

---

## Let another user in

The app's ACL is `luci-app-prometheus-exporter`. A LuCI user granted it can read and write `/etc/config/prometheus-exporter` and call the exporter's ubus object, and nothing else. With read access alone, the user sees the pages and a collector's options under **Edit**, but cannot save. See [LuCI app](../reference/luci.md#acl).
