#!/bin/sh
# Runs inside the pkgcheck container, with the built packages in /artifacts and
# the source tree in /exporter. Installs them offline, serves /metrics from a real
# uhttpd on loopback (with a real ubusd behind it), and checks what it answers.
set -u

: "${PKG_FULLVERSION:?run through make package-check}"
NAME=prometheus-node-exporter-ucode
BASE=/artifacts/$NAME-$PKG_FULLVERSION.apk
URL=http://127.0.0.1:9101/metrics
failures=0

pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
check() {
	desc=$1; shift
	if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

[ -f "$BASE" ] || { echo "no $BASE (run make package)" >&2; exit 1; }
SUBS=$(ls /artifacts/$NAME-*-$PKG_FULLVERSION.apk 2>/dev/null)
echo "checking $BASE" $SUBS

check "installs offline" apk add --allow-untrusted --no-network "$BASE" $SUBS
check "installs the base collectors" test -f /usr/share/ucode/node_exporter/collectors/loadavg.uc
check "keeps its config as a conffile" test -f /etc/config/$NAME
check "the init script parses" sh -n /etc/init.d/$NAME

check "the command line lists the collectors" sh -c "$NAME -l | grep -q '^loadavg '"
check "the command line scrapes" sh -c "$NAME loadavg | grep -q '^node_load1 '"

# What the init script starts, less procd's jail; procd's `system` object is a
# stand-in answering the caju router's board.
ubusd & sleep 1
ucode /exporter/devenv/scripts/system-board.uc /exporter/test/fixtures/caju-router/ubus/system.board.json &
sleep 1
/usr/sbin/uhttpd -f -c /dev/null -h /dev/null -S -D -o /metrics -O /usr/libexec/$NAME/handler.uc \
	-p 127.0.0.1:9101 2>/tmp/uhttpd.log &
sleep 1

fetch() { wget -q -O - "$1"; }
valid() {
	fetch "$URL" >/tmp/metrics &&
	ucode -e "import { parse } from 'node_exporter.exposition';
		let r = parse(require('fs').readfile('/tmp/metrics'));
		if (!r.ok) { warn(r.details, '\n'); exit(1); }"
}

check "uhttpd serves valid exposition text" valid
check "every installed collector succeeds" sh -c "! grep -q 'node_scrape_collector_success{.*} 0' /tmp/metrics"
check "the openwrt collector reads the board over ubus" grep -q '^node_openwrt_info{board_name="friendlyarm,nanopi-r5c",' /tmp/metrics
check "a query selects collectors" sh -c "fetch() { wget -q -O - \"\$1\"; }; fetch '$URL?collect[]=loadavg' | grep -q 'collector=\"loadavg\"' && ! fetch '$URL?collect[]=loadavg' | grep -q 'collector=\"openwrt\"'"
check "an unknown collector is refused" sh -c "! wget -q -O /dev/null '$URL?collect[]=nope'"

if [ "$failures" -gt 0 ]; then
	echo "--- uhttpd"; cat /tmp/uhttpd.log; echo "--- metrics"; cat /tmp/metrics 2>/dev/null
fi
echo "$failures failure(s)"
exit $((failures > 0))
