#!/bin/sh
# docs-links.sh: pinned docs links use the package's minor, or their CHANGELOG section's.
. "$(dirname "$0")/lib.sh"

root=$TMP/repo
site=https://example.org/ucode-prometheus-exporter

write() { mkdir -p "$(dirname "$root/$1")" && printf '%s\n' "$2" >"$root/$1"; }
links() { "$SCRIPTS/docs-links.sh" "$root"; }
passes() { links >/dev/null 2>&1 || { links; return 1; }; }
reports() { # LINE...: fails, listing exactly these misses
	expected=$(printf 'pinned docs links to the wrong version:\n'; printf '%s\n' "$@")
	refuses "$expected" links
}

write mkdocs.yml 'site_name: ucode-prometheus-exporter'
write openwrt/ucode-prometheus-exporter/Makefile 'PKG_VERSION:=0.10.2'
write src/prometheus_exporter/app.uc "// see $site/0.9/reference/"
write files/etc/config/prometheus-exporter "# $site/0.9/how-to/"
check "without site_url nothing is checked" passes

write mkdocs.yml "site_name: ucode-prometheus-exporter
site_url: $site/"
check "a stale pinned link in shipped files is reported" reports \
	"files/etc/config/prometheus-exporter:1: $site/0.9/ (expected 0.10)" \
	"src/prometheus_exporter/app.uc:1: $site/0.9/ (expected 0.10)"

write src/prometheus_exporter/app.uc "// see $site/0.10/reference/ and $site/latest/"
write files/etc/config/prometheus-exporter "# $site/0.10/how-to/ $site/0.10/"
check "links to the current minor and to latest pass" passes

write openwrt/ucode-prometheus-exporter/Makefile "PKG_VERSION:=0.10.2
  URL:=$site/0.1/"
check "the package Makefile is checked" reports \
	"openwrt/ucode-prometheus-exporter/Makefile:2: $site/0.1/ (expected 0.10)"
write openwrt/ucode-prometheus-exporter/Makefile "PKG_VERSION:=0.10.2
  URL:=$site/0.10/"

write luci/htdocs/luci-static/resources/view/prometheus-exporter/settings.js "// $site/0.9/how-to/"
check "the LuCI app is checked" reports \
	"luci/htdocs/luci-static/resources/view/prometheus-exporter/settings.js:1: $site/0.9/ (expected 0.10)"
write luci/htdocs/luci-static/resources/view/prometheus-exporter/settings.js "// $site/0.10/how-to/"

write mkdocs.yml "site_url: '$site'"
write files/etc/config/prometheus-exporter "# $site/0.10/ $site/0.11/x"
check "a quoted site_url without a trailing slash works" reports \
	"files/etc/config/prometheus-exporter:1: $site/0.11/ (expected 0.10)"
write files/etc/config/prometheus-exporter "# $site/0.10/"

write CHANGELOG.md "# Changelog

## [Unreleased]

- See $site/latest/how-to/.

## [0.10.0] - 2026-11-01

### Added

- Docs at $site/0.10/how-to/.

## [0.9.1] - 2026-10-15

- Fixed, see $site/0.9/reference/errors/."
check "CHANGELOG links matching their sections pass" passes

write CHANGELOG.md "# Changelog

## [Unreleased]

- See $site/0.10/how-to/.

## [0.10.0] - 2026-11-01

- Docs at $site/0.9/how-to/.

## [0.9.1] - 2026-10-15

- Fixed, see $site/0.10/reference/."
check "CHANGELOG links to another section's minor are reported" reports \
	"CHANGELOG.md:5: $site/0.10/ (outside a release section)" \
	"CHANGELOG.md:9: $site/0.9/ (expected 0.10)" \
	"CHANGELOG.md:13: $site/0.10/ (expected 0.9)"

finish
