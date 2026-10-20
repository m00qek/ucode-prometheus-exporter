# How to Update the Translation Template

The translation template `luci/po/templates/prometheus-exporter.pot` holds the LuCI app's strings: every `_('...')` in `luci/`. `make lint` fails while the template is out of date.

## Update it

After you add, change or move a string in the LuCI app:

```bash
make pot
```

It runs openwrt/luci's own scanner, `build/i18n-scan.pl`, over `luci/`, laid out as `applications/luci-app-prometheus-exporter` in the luci tree. So the template's location comments are the ones upstream would write. Commit the template with the change.

## If it fails

`pot: the scanner warned, so a string may be missing from the template` means the scanner lost its way in a file. The lines above name the file. Fix the string it stumbled on, often a quote inside `_()`, and run it again. It writes nothing while it warns.

---

The scanner runs in its own image, `ucode-prometheus-exporter-i18n`, from `devenv/services/i18n/Dockerfile`, without network.
