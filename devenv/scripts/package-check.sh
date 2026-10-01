#!/bin/sh
# Runs inside the pkgcheck container, with the built packages in /artifacts and
# the source tree in /exporter. Installs them offline, serves /metrics from a real
# uhttpd on loopback (with a real ubusd behind it), and checks what it answers.
set -u

: "${PKG_FULLVERSION:?run through make package-check}"
: "${BASE_COLLECTORS:?run through make package-check}"
# The package, and the service it installs (config, init script, command).
PKG=ucode-prometheus-exporter
NAME=prometheus-exporter
COLLECTORS=/usr/share/ucode/prometheus_exporter/collectors
BASE=/artifacts/$PKG-$PKG_FULLVERSION.apk
URL=http://127.0.0.1:9100/metrics
failures=0

pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
check() {
	desc=$1; shift
	if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

[ -f "$BASE" ] || { echo "no $BASE (run make package)" >&2; exit 1; }
GROUPS=$(/exporter/devenv/scripts/package-info.sh groups | cut -d' ' -f1)
SUBS=$(ls /artifacts/$PKG-*-$PKG_FULLVERSION.apk 2>/dev/null)
is_group() { for g in $GROUPS; do [ "$1" = "/artifacts/$PKG-$g-$PKG_FULLVERSION.apk" ] && return 0; done; return 1; }
COLLECTOR_PKGS=$(for s in $SUBS; do is_group "$s" || echo "$s"; done)
echo "checking $BASE" $SUBS

check "installs offline" apk add --allow-untrusted --no-network "$BASE" $SUBS
installed() { ls $COLLECTORS/*.uc | wc -l; }
all_base_installed() { for c in $BASE_COLLECTORS; do [ -f "$COLLECTORS/$c.uc" ] || return 1; done; }
check "installs the base collectors" all_base_installed
check "installs one collector per subpackage" test "$(installed)" -eq $(($(echo $BASE_COLLECTORS | wc -w) + $(echo $COLLECTOR_PKGS | wc -w)))

# A group depends on the exporter and exactly its collectors' packages (and the
# libc every package does), and installs no files but apk's own list of them.
group_is() {
	g=$1; shift
	want=$(for c in "$@"; do echo "$PKG-$c"; done; echo "$PKG"; echo libc)
	have=$(apk info -R "$PKG-$g" 2>/dev/null | tail -n +2 | sed 's/[<>=~].*//' | grep -v '^$')
	files=$(apk info -L "$PKG-$g" 2>/dev/null | tail -n +2 | grep -v -e '^$' -e '^lib/apk/packages/')
	[ "$(echo "$want" | sort -u)" = "$(echo "$have" | sort -u)" ] && [ -z "$files" ]
}
# Not in a pipeline: check() counts failures, which a subshell would lose.
while read -r g members; do
	check "the $g group is its collectors" group_is "$g" $members
done <<EOF
$(/exporter/devenv/scripts/package-info.sh groups)
EOF
check "keeps its config as a conffile" test -f /etc/config/$NAME
check "the init script parses" sh -n /etc/init.d/$NAME

check "every installed collector loads" test "$($NAME -l 2>/dev/null | wc -l)" -eq "$(installed)"
check "the command line scrapes" sh -c "$NAME loadavg | grep -q '^node_load1 '"

# What the init script starts, less procd's jail; procd's and netifd's objects are
# stand-ins answering with the caju router's replies.
ubusd & sleep 1
ucode /exporter/devenv/scripts/ubus-stand-ins.uc /exporter/test/fixtures/caju-router &
sleep 1
/usr/sbin/uhttpd -f -c /dev/null -h /dev/null -S -D -o /metrics -O /usr/libexec/$NAME/handler.uc \
	-p 127.0.0.1:9100 2>/tmp/uhttpd.log &
sleep 1

fetch() { wget -q -O - "$1"; }
valid() {
	fetch "$URL" >/tmp/metrics &&
	ucode -e "import { parse } from 'prometheus_exporter.exposition';
		let r = parse(require('fs').readfile('/tmp/metrics'));
		if (!r.ok) { warn(r.details, '\n'); exit(1); }"
}

check "uhttpd serves valid exposition text" valid
base_succeed() { for c in $BASE_COLLECTORS; do grep -q "^node_scrape_collector_success{collector=\"$c\"} 1$" /tmp/metrics || return 1; done; }
# Subpackage collectors read hardware and services a container lacks: they only
# have to answer. The base ones have what they need here.
check "every installed collector answers" test "$(grep -c '^node_scrape_collector_success{' /tmp/metrics)" -eq "$(installed)"
check "every base collector succeeds" base_succeed
check "it reports the package's version" grep -qx "ucode_prometheus_exporter_build_info{version=\"$PKG_FULLVERSION\"} 1" /tmp/metrics
check "the openwrt collector reads the board over ubus" grep -q '^node_openwrt_info{board_name="friendlyarm,nanopi-r5c",' /tmp/metrics
check "a query selects collectors" sh -c "fetch() { wget -q -O - \"\$1\"; }; fetch '$URL?collect[]=loadavg' | grep -q 'collector=\"loadavg\"' && ! fetch '$URL?collect[]=loadavg' | grep -q 'collector=\"openwrt\"'"
check "an unknown collector is refused" sh -c "! wget -q -O /dev/null '$URL?collect[]=nope'"

# ---- luci-app-prometheus-exporter ----
# The LuCI app on top of the exporter: its files, its package scripts, and its plugin
# in a real rpcd on the ubusd above.
APP=/artifacts/luci-app-$NAME-$PKG_FULLVERSION.apk
APP_LIST=/lib/apk/packages/luci-app-$NAME.list
VIEWS=/www/luci-static/resources/view/$NAME
APP_FILES="/usr/share/luci/menu.d/luci-app-$NAME.json /usr/share/rpcd/acl.d/luci-app-$NAME.json
	/www/luci-static/resources/$NAME.js $VIEWS/settings.js $VIEWS/status.js
	/usr/share/ucode/prometheus_exporter/luci/rpc.uc /usr/share/rpcd/ucode/$NAME.uc"
STATUS_HELPER=/usr/libexec/$NAME/luci-status.uc

has_mode() { [ -n "$(find "$2" -prune -perm "$1")" ]; }
pins_exporter() { apk adbdump "$APP" | grep -qx "    - $PKG=$PKG_FULLVERSION"; }
seed_luci_caches() { mkdir -p /tmp/luci-modulecache && touch /tmp/luci-indexcache.test.json /tmp/luci-modulecache/test; }
luci_caches_cleared() { [ ! -e /tmp/luci-indexcache.test.json ] && [ ! -e /tmp/luci-modulecache ]; }
parses() {
	case $1 in
	*.json) ucode -e 'json(require("fs").readfile(ARGV[0]))' "$1" ;;
	# LuCI compiles a view as a function body (top-level `return`).
	*.js) qjs --std -e 'new Function(std.loadFile(scriptArgs[0]))' "$1" ;;
	# A module is loaded, from the default search path.
	/usr/share/ucode/*) ucode -e "import * as _ from '$1';" ;;
	*) ucode -c -o /dev/null "$1" ;;
	esac
}
# The number of collectors in a reply of the plugin.
collectors_in() { ucode -e 'print(length(json(ARGV[0]).collectors))' "$1"; }

[ -f "$APP" ] || fail "no $APP (run make package)"
check "app pins the exporter's version" pins_exporter
seed_luci_caches
check "app installs offline" apk add --allow-untrusted --no-network "$APP"
check "app install clears the LuCI caches" luci_caches_cleared
check "app ships its menu, ACL, views, module, plugin and status helper only" \
	test "$(grep -c . "$APP_LIST")" -eq "$(($(echo $APP_FILES | wc -w) + 1))"
for f in $APP_FILES; do
	check "$f 0644" has_mode 644 "$f"
	check "$f parses" parses "$f"
done
check "$STATUS_HELPER 0755" has_mode 755 "$STATUS_HELPER"

rpcd &
check "rpcd serves the plugin" ubus -t 10 wait_for "$NAME"
reply=$(ubus -t 30 call "$NAME" collectors 2>/dev/null)
check "collectors lists every installed collector" test "$(collectors_in "$reply")" -eq "$(installed)"
check "validate refuses what the init script would" sh -c \
	"ubus -t 30 call $NAME validate '{\"main\":{\"listen_port\":\"0\"}}' | grep -q 'expected an integer from 1 to 65535, got 0'"
# No procd here: status says so, and still scrapes, in a process of its own.
reply=$(ubus -t 30 call "$NAME" status 2>/dev/null)
check "status scrapes every enabled collector" test "$(collectors_in "$reply")" -eq "$(installed)"
status_unknown() { echo "$reply" | grep -q '"running": null'; }
check "status says when procd cannot be asked" status_unknown

seed_luci_caches
app_removed() {
	apk del "luci-app-$NAME" >/dev/null 2>&1 || return 1
	for f in $APP_FILES "$STATUS_HELPER"; do [ ! -e "$f" ] || return 1; done
	apk info -e "$PKG" >/dev/null
}
check "app removes cleanly and keeps the exporter" app_removed
check "app removal clears the LuCI caches" luci_caches_cleared
# ---- end luci-app-prometheus-exporter ----

if [ "$failures" -gt 0 ]; then
	echo "--- uhttpd"; cat /tmp/uhttpd.log; echo "--- metrics"; cat /tmp/metrics 2>/dev/null
fi
echo "$failures failure(s)"
exit $((failures > 0))
