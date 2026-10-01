#!/bin/sh
# make pot, and the check in make lint: the LuCI app's translation template as
# openwrt/luci's build/i18n-scan.pl writes it (devenv/services/i18n), run over the app
# laid out as in the luci tree, so the location comments are the ones upstream would
# write. As in wgpathd.
# usage: pot.sh [check]
# `check` fails when the template is out of date. Both fail when the scanner warns: a
# warning means it may have lost its way in a file and missed strings.
set -eu
cd "$(dirname "$0")/../.."

: "${I18N_IMAGE:?run through make}"

APP=luci-app-prometheus-node-exporter-ucode
POT=luci/po/templates/prometheus-node-exporter-ucode.pot
out=$(mktemp)
err=$(mktemp)
trap 'rm -f "$out" "$err"' EXIT

docker build -q -t "$I18N_IMAGE" devenv/services/i18n >/dev/null
docker run --rm --network none -v "$PWD/luci:/luci/applications/$APP:ro" -w /luci "$I18N_IMAGE" \
	i18n-scan.pl "applications/$APP" >"$out" 2>"$err"

if [ -s "$err" ]; then
	cat "$err" >&2
	echo "pot: the scanner warned, so a string may be missing from the template" >&2
	exit 1
fi

if [ "${1:-}" = check ]; then
	diff -u "$POT" "$out" >&2 || { echo "$POT is out of date: run make pot" >&2; exit 1; }
else
	cp "$out" "$POT"
fi
