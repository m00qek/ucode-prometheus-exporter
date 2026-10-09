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
# The command line, a package of its own, and its modules.
CLI=/artifacts/$PKG-cli-$PKG_FULLVERSION.apk
CLI_FILES="/usr/bin/$NAME /usr/share/ucode/prometheus_exporter/cli.uc /usr/share/ucode/prometheus_exporter/conform.uc"
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
SUBS=$(ls /artifacts/$PKG-*-$PKG_FULLVERSION.apk 2>/dev/null | grep -vx "$CLI")
is_group() { for g in $GROUPS; do [ "$1" = "/artifacts/$PKG-$g-$PKG_FULLVERSION.apk" ] && return 0; done; return 1; }
COLLECTOR_PKGS=$(for s in $SUBS; do is_group "$s" || echo "$s"; done)
echo "checking $BASE" $SUBS

# The feed's exporters it replaces: apk refuses it beside one, and one beside it.
# The image holds the feed's ucode exporter (the Lua one needs Lua).
FEED_UCODE=prometheus-node-exporter-ucode
conflicts_with() { apk adbdump "$BASE" | grep -qx "    - '!$1>=0'"; }
refused() { ! apk add --allow-untrusted --no-network "$@" >/tmp/apk.log 2>&1 && grep -q "breaks: $PKG-$PKG_FULLVERSION\[!$FEED_UCODE>=0\]" /tmp/apk.log; }
check "it conflicts with the feed's ucode exporter" conflicts_with "$FEED_UCODE"
check "and with the feed's Lua exporter" conflicts_with prometheus-node-exporter-lua
apk add --allow-untrusted --no-network /opt/feed/$FEED_UCODE-*.apk >/dev/null 2>&1
check "apk refuses it beside the feed's ucode exporter" refused "$BASE"
apk del "$FEED_UCODE" >/dev/null 2>&1

check "installs offline" apk add --allow-untrusted --no-network "$BASE" $SUBS
check "apk refuses the feed's ucode exporter beside it" refused /opt/feed/$FEED_UCODE-*.apk
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
check "and basic auth's hash's apart, mode 0600" sh -c "test -f /etc/config/$NAME-auth && ls -l /etc/config/$NAME-auth | grep -q '^-rw------- '"
check "makes the user and group uhttpd runs as in its jail" sh -c "grep -q '^$NAME:x:[0-9]*:[0-9]*:' /etc/passwd && grep -q '^$NAME:x:[0-9]*:' /etc/group"
check "ships ubusd's link to the ubus ACL the service writes" test "$(readlink /usr/share/acl.d/$NAME.json)" = "/var/run/$NAME.acl.json"
check "runs its uci-defaults script once" test ! -e /etc/uci-defaults/$NAME-import
check "the init script parses" sh -n /etc/init.d/$NAME

# The base package, without the command line: no command, no ucode-docopt,
# and its own check, which the init script runs.
CHECK_HELPER=/usr/libexec/$NAME/check.uc
no_cli_files() { for f in $CLI_FILES; do [ ! -e "$f" ] || return 1; done; }
check "the base package has no command line" no_cli_files
check "and does not depend on ucode-docopt" sh -c "! apk info -R $PKG | grep -q '^ucode-docopt'"
check "it ships the init script's check, $CHECK_HELPER, 0755" sh -c "grep -qx '$CHECK_HELPER' /lib/apk/packages/$PKG.list && [ -n \"\$(find '$CHECK_HELPER' -prune -perm 755)\" ]"
check "which takes the installed config" sh -c "$CHECK_HELPER --config | grep -q '^ok   main: '"

[ -f "$CLI" ] || fail "no $CLI (run make package)"
check "the command line's package installs offline" apk add --allow-untrusted --no-network "$CLI"
cli_ships() { [ "$(grep . /lib/apk/packages/$PKG-cli.list | sort)" = "$(printf '%s\n' $CLI_FILES | sort)" ]; }
check "it ships the command and its modules alone" cli_ships
check "it depends on the exporter and ucode-docopt" sh -c "[ \"\$(apk info -R $PKG-cli | tail -n +2 | sed 's/[<>=~].*//' | grep -v '^\$' | sort -u | tr '\n' ' ')\" = 'libc ucode-docopt $PKG ' ]"
check "and pins the exporter's version" sh -c "apk adbdump '$CLI' | grep -qx '    - $PKG=$PKG_FULLVERSION'"
check "the command is 0755" sh -c "[ -n \"\$(find /usr/bin/$NAME -prune -perm 755)\" ]"

check "every installed collector loads" test "$($NAME collector list 2>/dev/null | wc -l)" -eq "$(installed)"
check "the command line scrapes" sh -c "$NAME scrape loadavg | grep -q '^node_load1 '"

# What the init script starts, less procd's jail; procd's and netifd's objects are
# stand-ins answering with the caju router's replies, and procd's service list
# and rpcd's rc say nothing runs here (until rpcd starts, below).
ubusd & sleep 1
ucode /exporter/devenv/scripts/ubus-stand-ins.uc /exporter/test/fixtures/caju-router &
ucode /exporter/devenv/scripts/ubus-stand-ins.uc /exporter/test/fixtures/caju-router services &
services_stand_in=$!
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
gzipped() { wget -q -O - --header='Accept-Encoding: gzip' "$URL" | gzip -dc | grep -q '^node_load1 '; }
check "a scrape asked for gzip is gzipped" gzipped

# hash_password's hash ($6$, 1000 rounds) as musl's crypt takes it: uhttpd checks
# basic auth itself for a file, here under a realm of its own.
mkdir -p /tmp/www && echo hello >/tmp/www/hello
hash_ok() {
	hash=$(ucode -e "import { hash_password } from 'prometheus_exporter.auth';
		import { readfile } from 'fs';
		print(hash_password('pkg-secret', (n) => readfile('/dev/urandom', n)).data);") || return 1
	printf '/:prom:%s\n' "$hash" >/tmp/realm.conf
	/usr/sbin/uhttpd -f -c /tmp/realm.conf -r check -h /tmp/www -p 127.0.0.1:9180 2>/dev/null &
	realm=$!
	sleep 1
	ok=$(wget -q -O - --user=prom --password=pkg-secret http://127.0.0.1:9180/hello)
	wget -q -O /dev/null --user=prom --password=wrong http://127.0.0.1:9180/hello && ok=
	kill "$realm" 2>/dev/null
	[ "$ok" = hello ]
}
check "musl's crypt takes the hash hash_password makes" hash_ok

# ---- the service's ubus object ----
# rpcd serves it from the base package's plugin, with no LuCI app installed.
PLUGIN=/usr/share/rpcd/ucode/$NAME.uc
RPC_MODULE=/usr/share/ucode/prometheus_exporter/rpc.uc
STATUS_HELPER=/usr/libexec/$NAME/rpc-status.uc
BASE_LIST=/lib/apk/packages/$PKG.list

has_mode() { [ -n "$(find "$2" -prune -perm "$1")" ]; }
fails() { ! "$@"; }
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
# The packages $1 depends on, by name, sorted, on one line.
depends_of() { apk info -R "$1" 2>/dev/null | tail -n +2 | sed 's/[<>=~].*//' | grep -v '^$' | sort -u | tr '\n' ' '; }
depends_on() { depends_of "$1" | grep -qw -- "$2"; }
# The number of collectors in a reply.
collectors_in() { ucode -e 'print(length(json(ARGV[0]).collectors))' "$1"; }

for f in $PLUGIN $RPC_MODULE $STATUS_HELPER; do
	check "the base package ships $f" grep -qx "$f" "$BASE_LIST"
	check "$f parses" parses "$f"
done
# Every module of the source tree but the collectors, the subdirectories split
# out of a module (exposition/ ...) included: shipped, and each loads.
library() { cd /exporter/src && find prometheus_exporter -name '*.uc' ! -path 'prometheus_exporter/collectors/*' ! -name cli.uc ! -name conform.uc | sort; }
ships_library() { for f in $(library); do grep -qx "/usr/share/ucode/$f" "$BASE_LIST" || return 1; done; }
library_loads() { for f in $(library); do parses "/usr/share/ucode/$f" || return 1; done; }
check "the base package ships every module of the exporter, in their directories" ships_library
check "each of them loads" library_loads
check "$PLUGIN 0644" has_mode 644 "$PLUGIN"
check "$RPC_MODULE 0644" has_mode 644 "$RPC_MODULE"
check "$STATUS_HELPER 0755" has_mode 755 "$STATUS_HELPER"
check "the base package depends on rpcd-mod-ucode" depends_on "$PKG" rpcd-mod-ucode
check "and on ucode-mod-uloop, for status" depends_on "$PKG" ucode-mod-uloop
check "and on ucode-mod-log, to log at each message's priority" depends_on "$PKG" ucode-mod-log
check "and on ucode-mod-zlib, to gzip a scrape" depends_on "$PKG" ucode-mod-zlib
check "and on ucode-mod-digest, for basic auth's crypt" depends_on "$PKG" ucode-mod-digest
AUTH_HELPER=/usr/libexec/$NAME/auth.uc
check "the base package ships $AUTH_HELPER" grep -qx "$AUTH_HELPER" "$BASE_LIST"
check "$AUTH_HELPER 0755" has_mode 755 "$AUTH_HELPER"
check "$AUTH_HELPER parses" parses "$AUTH_HELPER"
NTP_HOOK=/etc/hotplug.d/ntp/90-$NAME
check "the base package ships $NTP_HOOK, for timesync" grep -qx "$NTP_HOOK" "$BASE_LIST"
check "$NTP_HOOK parses" sh -n "$NTP_HOOK"
check "no LuCI app is installed" fails apk info -e "luci-app-$NAME"
# filesystem's own rpcd plugin, its object's statvfs() of the host's mounts.
FS_PLUGIN=/usr/share/rpcd/ucode/$NAME-filesystem.uc
check "the filesystem package ships $FS_PLUGIN" grep -qx "$FS_PLUGIN" "/lib/apk/packages/$PKG-filesystem.list"
check "$FS_PLUGIN 0644" has_mode 644 "$FS_PLUGIN"
check "$FS_PLUGIN parses" parses "$FS_PLUGIN"

kill "$services_stand_in"; sleep 1
rpcd &
check "rpcd serves the ubus object" ubus -t 10 wait_for "$NAME"
check "and filesystem's, with each mount's inodes" sh -c \
	"ubus -t 30 call $NAME.filesystem mounts | jsonfilter -e '@.result[*].ffree' | grep -q '^[0-9]'"
reply=$(ubus -t 30 call "$NAME" collectors 2>/dev/null)
check "collectors lists every installed collector" test "$(collectors_in "$reply")" -eq "$(installed)"
check "validate refuses what the init script would" sh -c \
	"ubus -t 30 call $NAME validate '{\"main\":{\"listen_port\":\"0\"}}' | grep -q 'expected an integer from 1 to 65535, got 0'"
hashes() { ubus -t 30 call "$NAME" hash_password '{"password":"pkg-secret"}' | jsonfilter -e '@.hash' | grep -q '^\$6\$rounds=1000\$'; }
check "hash_password hashes a password, as SHA-512-crypt" hashes
# No procd here: status says so, and still scrapes, in a process of its own.
reply=$(ubus -t 30 call "$NAME" status 2>/dev/null)
check "status scrapes every enabled collector" test "$(collectors_in "$reply")" -eq "$(installed)"
status_unknown() { echo "$reply" | grep -q '"running": null'; }
check "status says when procd cannot be asked" status_unknown
# netifd's stand-in answers the caju router's interfaces: their names and
# protocols, and nothing else.
interfaces_are_netifds() {
	ubus -t 30 call "$NAME" interfaces >/tmp/interfaces.json 2>/dev/null &&
	ucode -e "let fs = require('fs');
		let got = json(fs.readfile('/tmp/interfaces.json')).interfaces;
		let want = map(json(fs.readfile(ARGV[0])).interface, (i) => ({ name: i.interface, proto: i.proto }));
		exit(length(want) > 0 && sprintf('%J', got) == sprintf('%J', want) ? 0 : 1);" \
		/exporter/test/fixtures/caju-router/ubus/network.interface.dump.json
}
check "interfaces lists netifd's interfaces, by name and protocol" interfaces_are_netifds

# ---- luci-app-prometheus-exporter ----
# The LuCI app on top of the exporter: its views, menu, resource and ACL, and its
# package scripts. The ubus object it calls is the base package's.
APP=/artifacts/luci-app-$NAME-$PKG_FULLVERSION.apk
APP_LIST=/lib/apk/packages/luci-app-$NAME.list
VIEWS=/www/luci-static/resources/view/$NAME
ACL=/usr/share/rpcd/acl.d/luci-app-$NAME.json
APP_FILES="/usr/share/luci/menu.d/luci-app-$NAME.json $ACL
	/www/luci-static/resources/$NAME.js /www/luci-static/resources/$NAME/widgets.js $VIEWS/settings.js $VIEWS/status.js"
APP_METHODS="'collectors', 'interfaces', 'password', 'status', 'validate'"

pins_exporter() { apk adbdump "$APP" | grep -qx "    - $PKG=$PKG_FULLVERSION"; }
seed_luci_caches() { mkdir -p /tmp/luci-modulecache && touch /tmp/luci-indexcache.test.json /tmp/luci-modulecache/test; }
luci_caches_cleared() { [ ! -e /tmp/luci-indexcache.test.json ] && [ ! -e /tmp/luci-modulecache ]; }
# luci-base and the exporter, and the libc every package depends on.
app_depends() { [ "$(depends_of "luci-app-$NAME")" = "libc luci-base $PKG " ]; }
# The ACL grants the object's methods (set_password to a login that may save),
# and the exporter's config to read and write: nothing else, not the hash's.
acl_is_ours() {
	ucode -e "let acl = json(require('fs').readfile(ARGV[0]));
		let want = { 'luci-app-$NAME': {
			description: acl['luci-app-$NAME']?.description,
			read: { ubus: { '$NAME': [ $APP_METHODS ] }, uci: [ '$NAME' ] },
			write: { ubus: { '$NAME': [ 'set_password' ] }, uci: [ '$NAME' ] } } };
		exit(sprintf('%J', acl) == sprintf('%J', want) ? 0 : 1);" "$ACL"
}
plugin_kept() { for f in $PLUGIN $RPC_MODULE $STATUS_HELPER; do [ -f "$f" ] || return 1; done; }

[ -f "$APP" ] || fail "no $APP (run make package)"
check "app pins the exporter's version" pins_exporter
seed_luci_caches
check "app installs offline" apk add --allow-untrusted --no-network "$APP"
check "app install clears the LuCI caches" luci_caches_cleared
app_files_are() { [ "$(grep . "$APP_LIST" | sort)" = "$(printf '%s\n' $APP_FILES | sort)" ]; }
check "app ships its menu, ACL, resource and views only" app_files_are
for f in $APP_FILES; do
	check "$f 0644" has_mode 644 "$f"
	check "$f parses" parses "$f"
done
check "app depends on luci-base and the exporter alone" app_depends
check "its ACL grants the ubus object's methods and the exporter's config, nothing of basic auth's" acl_is_ours

seed_luci_caches
app_removed() {
	apk del "luci-app-$NAME" >/dev/null 2>&1 || return 1
	for f in $APP_FILES; do [ ! -e "$f" ] || return 1; done
	apk info -e "$PKG" >/dev/null
}
check "app removes cleanly and keeps the exporter" app_removed
check "app removal clears the LuCI caches" luci_caches_cleared
check "and keeps the ubus object's plugin" plugin_kept
reply=$(ubus -t 30 call "$NAME" collectors 2>/dev/null)
check "which still answers" test "$(collectors_in "$reply")" -eq "$(installed)"
# ---- end luci-app-prometheus-exporter ----

if [ "$failures" -gt 0 ]; then
	echo "--- uhttpd"; cat /tmp/uhttpd.log; echo "--- metrics"; cat /tmp/metrics 2>/dev/null
fi
echo "$failures failure(s)"
exit $((failures > 0))
