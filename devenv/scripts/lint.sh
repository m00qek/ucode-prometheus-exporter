#!/bin/sh
# Runs inside the openwrt container, on OpenWrt 25.12's ucode.
cd "$(dirname "$0")/../.."
status=0
src=$PWD/src
scripts=$PWD/devenv/scripts

fail() { echo "  in $1" >&2; status=1; }

# Modules are loaded, not only compiled: `ucode -c` accepts a named import the
# module does not export, loading does not. So every native function
# prometheus_exporter.deps takes by name is checked against this ucode.
for f in $(find src -name '*.uc'); do
	ucode -L "$src" -e "import * as _ from '$PWD/$f';" || fail "$f"
done

# The docs generator's modules and its notes, loaded too.
for f in $(find devenv/scripts/docs_gen docs/gen -name '*.uc'); do
	ucode -L "$src" -L "$scripts" -e "import * as _ from '$PWD/$f';" || fail "$f"
done

# rtnl, nl80211 and socket are imported at run time, by name too; the image has them.
for m in rtnl nl80211 socket; do
	ucode -L "$src" -e "import { load_$m } from 'prometheus_exporter.deps'; exit(load_$m() ? 0 : 1);" ||
		{ echo "prometheus_exporter.deps: $m does not load" >&2; status=1; }
done

# zlib (gzip, in http.uc) and digest (basic auth's crypt, in crypt.uc) are imported
# by name above; what they compute is checked here, on this ucode: a gzip header,
# and an MD5 as hex.
ucode -e "import { deflate, inflate } from 'zlib'; let g = deflate('x', true, 1);
	exit(substr(g, 0, 3) == '\x1f\x8b\x08' && inflate(g) == 'x' ? 0 : 1);" ||
	{ echo "zlib: deflate does not write gzip" >&2; status=1; }
ucode -e "import { md5 } from 'digest'; exit(md5('') == 'd41d8cd98f00b204e9800998ecf8427e' ? 0 : 1);" ||
	{ echo "digest: md5 is not hex" >&2; status=1; }

# Tests import utest's mocks, which exist only while utest runs: compile them.
importer=$(mktemp)
for f in $(find test -name '*.uc' ! -name utest.config.uc ! -path 'test/proxies/*'); do
	echo "import * as _ from '$PWD/$f';" >"$importer"
	ucode -L "$src" -L "$PWD/test" -L "$scripts" -c -o /dev/null "$importer" || fail "$f"
done
rm -f "$importer"

# Programs: the utest config and proxies return at top level; the handler is a template.
for f in test/utest.config.uc test/proxies/*.uc devenv/scripts/*.uc; do
	ucode -L "$src" -L "$scripts" -c -o /dev/null "$f" || fail "$f"
done
ucode -L "$src" -T -c -o /dev/null files/usr/libexec/prometheus-exporter/handler.uc ||
	fail files/usr/libexec/prometheus-exporter/handler.uc
for f in files/usr/libexec/prometheus-exporter/*.uc; do
	[ "$f" = files/usr/libexec/prometheus-exporter/handler.uc ] ||
		ucode -L "$src" -c -o /dev/null "$f" || fail "$f"
done
ucode -L "$src" files/usr/bin/prometheus-exporter -h >/dev/null ||
	fail files/usr/bin/prometheus-exporter

for f in files/etc/init.d/* files/etc/uci-defaults/* files/etc/hotplug.d/*/* devenv/scripts/*.sh devenv/services/lab/*.sh test/feed/*.sh; do
	sh -n "$f" || fail "$f"
done

# The rpcd plugin, the service's ubus object, returns at top level.
for f in files/usr/share/rpcd/ucode/*.uc; do
	ucode -L "$src" -c -o /dev/null "$f" || fail "$f"
done

# ---- luci-app-prometheus-exporter ----
# The browser tests' fake procd is a program that runs at top level.
for f in devenv/services/luci/*.uc; do
	ucode -L "$src" -c -o /dev/null "$f" || fail "$f"
done
for f in devenv/services/luci/*.sh; do
	sh -n "$f" || fail "$f"
done

for f in $(find luci test/fixtures/luci devenv/services/luci -name '*.json'); do
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

# The docs: pinned links to the package's minor, and the reference pages the
# code holds as data as make docs-gen would write them.
devenv/scripts/docs-links.sh || status=1
ucode -L "$src" -L "$scripts" devenv/scripts/docs-gen.uc --check || status=1

# The package feed's Makefile, and what its generator refuses (offline).
sh test/feed/feed_makefile_test.sh >/dev/null || { sh test/feed/feed_makefile_test.sh | grep -v '^ok '; status=1; }

exit $status
