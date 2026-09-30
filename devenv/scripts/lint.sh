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

# nl80211 is imported at run time, by name too; the image has it installed.
ucode -L "$src" -e "import { load_nl80211 } from 'node_exporter.deps'; exit(load_nl80211() ? 0 : 1);" ||
	{ echo 'node_exporter.deps: nl80211 does not load' >&2; status=1; }

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
ucode -L "$src" files/usr/bin/prometheus-node-exporter-ucode -h >/dev/null ||
	fail files/usr/bin/prometheus-node-exporter-ucode

for f in files/etc/init.d/* devenv/scripts/*.sh; do
	sh -n "$f" || fail "$f"
done

exit $status
