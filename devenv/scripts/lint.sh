#!/bin/sh
# Runs inside the openwrt container, on OpenWrt 25.12's ucode.
cd "$(dirname "$0")/../.."
status=0
src=$PWD/src

fail() { echo "  in $1" >&2; status=1; }

# Modules are loaded, not only compiled: `ucode -c` accepts a named import the
# module does not export, loading does not. So every native function
# node_exporter.deps takes by name is checked against this ucode.
for f in $(find src -name '*.uc'); do
	ucode -L "$src" -e "import * as _ from '$PWD/$f';" || fail "$f"
done

# rtnl, nl80211 and socket are imported at run time, by name too; the image has them.
for m in rtnl nl80211 socket; do
	ucode -L "$src" -e "import { load_$m } from 'node_exporter.deps'; exit(load_$m() ? 0 : 1);" ||
		{ echo "node_exporter.deps: $m does not load" >&2; status=1; }
done

# Tests import utest's mocks, which exist only while utest runs: compile them.
importer=$(mktemp)
for f in $(find test -name '*.uc' ! -name utest.config.uc ! -path 'test/proxies/*'); do
	echo "import * as _ from '$PWD/$f';" >"$importer"
	ucode -L "$src" -L "$PWD/test" -c -o /dev/null "$importer" || fail "$f"
done
rm -f "$importer"

# Programs: the utest config and proxies return at top level; the handler is a template.
for f in test/utest.config.uc test/proxies/*.uc devenv/scripts/*.uc; do
	ucode -c -o /dev/null "$f" || fail "$f"
done
ucode -L "$src" -T -c -o /dev/null files/usr/libexec/prometheus-node-exporter-ucode/handler.uc ||
	fail files/usr/libexec/prometheus-node-exporter-ucode/handler.uc
for f in files/usr/libexec/prometheus-node-exporter-ucode/*.uc; do
	[ "$f" = files/usr/libexec/prometheus-node-exporter-ucode/handler.uc ] ||
		ucode -L "$src" -c -o /dev/null "$f" || fail "$f"
done
ucode -L "$src" files/usr/bin/prometheus-node-exporter-ucode -h >/dev/null ||
	fail files/usr/bin/prometheus-node-exporter-ucode

for f in files/etc/init.d/* devenv/scripts/*.sh; do
	sh -n "$f" || fail "$f"
done

# ---- luci-app-prometheus-node-exporter-ucode ----
# The rpcd plugin is a program that returns at top level.
for f in files/usr/share/rpcd/ucode/*.uc; do
	ucode -L "$src" -c -o /dev/null "$f" || fail "$f"
done

for f in $(find luci -name '*.json'); do
	ucode -e 'json(require("fs").readfile(ARGV[0]))' "$f" || fail "$f"
done

# LuCI compiles a view as a function body (top-level `return`), so it is parsed the same way.
for f in $(find luci -name '*.js'); do
	qjs --std -e 'new Function(std.loadFile(scriptArgs[0]))' "$f" || fail "$f"
done

devenv/scripts/luci-dom-lint.sh $(find luci/htdocs -name '*.js') || status=1

# The check above must still catch what it is for.
bad=$(mktemp)
for line in "el.innerHTML = x;" "_('Collector %s').format(name);" "'%s'.format(name);"; do
	echo "$line" >"$bad"
	devenv/scripts/luci-dom-lint.sh "$bad" >/dev/null 2>&1 &&
		{ echo "luci-dom-lint.sh let through: $line" >&2; status=1; }
done
rm -f "$bad"

exit $status
