#!/bin/sh
# Runs inside the pkgcheck container, with the built packages in /artifacts and
# the source tree in /exporter. Installs them offline, serves /metrics from a real
# uhttpd on loopback (with a real ubusd behind it), and checks what it answers.
set -u

: "${PKG_FULLVERSION:?run through make package-check}"
: "${BASE_COLLECTORS:?run through make package-check}"
NAME=prometheus-node-exporter-ucode
COLLECTORS=/usr/share/ucode/node_exporter/collectors
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
installed() { ls $COLLECTORS/*.uc | wc -l; }
all_base_installed() { for c in $BASE_COLLECTORS; do [ -f "$COLLECTORS/$c.uc" ] || return 1; done; }
check "installs the base collectors" all_base_installed
check "installs one collector per subpackage" test "$(installed)" -eq $(($(echo $BASE_COLLECTORS | wc -w) + $(echo $SUBS | wc -w)))
check "keeps its config as a conffile" test -f /etc/config/$NAME
check "the init script parses" sh -n /etc/init.d/$NAME

check "every installed collector loads" test "$($NAME -l 2>/dev/null | wc -l)" -eq "$(installed)"
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
base_succeed() { for c in $BASE_COLLECTORS; do grep -q "^node_scrape_collector_success{collector=\"$c\"} 1$" /tmp/metrics || return 1; done; }
# Subpackage collectors read hardware and services a container lacks: they only
# have to answer. The base ones have what they need here.
check "every installed collector answers" test "$(grep -c '^node_scrape_collector_success{' /tmp/metrics)" -eq "$(installed)"
check "every base collector succeeds" base_succeed
check "the openwrt collector reads the board over ubus" grep -q '^node_openwrt_info{board_name="friendlyarm,nanopi-r5c",' /tmp/metrics
check "a query selects collectors" sh -c "fetch() { wget -q -O - \"\$1\"; }; fetch '$URL?collect[]=loadavg' | grep -q 'collector=\"loadavg\"' && ! fetch '$URL?collect[]=loadavg' | grep -q 'collector=\"openwrt\"'"
check "an unknown collector is refused" sh -c "! wget -q -O /dev/null '$URL?collect[]=nope'"

if [ "$failures" -gt 0 ]; then
	echo "--- uhttpd"; cat /tmp/uhttpd.log; echo "--- metrics"; cat /tmp/metrics 2>/dev/null
fi
echo "$failures failure(s)"
exit $((failures > 0))
