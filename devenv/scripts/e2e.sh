#!/bin/sh
# Runs inside a privileged pkgcheck container booted with /sbin/init (procd,
# ubusd, netifd), with the built packages in /artifacts: make e2e. Installs
# the exporter as a device would, and checks the service under procd, in its
# jail, as packages come and go and its config changes.
set -u

: "${PKG_FULLVERSION:?run through make e2e}"
: "${BASE_COLLECTORS:?run through make e2e}"
# The package, and the service it installs (config, init script, command).
PKG=ucode-prometheus-exporter
NAME=prometheus-exporter
INIT=/etc/init.d/$NAME
LIBEXEC=/usr/libexec/$NAME
URL=http://127.0.0.1:9100/metrics
failures=0

pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
check() {
	desc=$1; shift
	if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
# Retries for up to 20 seconds: reloads come from procd's triggers, a second late.
eventually() {
	desc=$1; shift
	i=0
	while [ $i -lt 20 ]; do
		"$@" >/dev/null 2>&1 && { pass "$desc"; return 0; }
		i=$((i + 1)); sleep 1
	done
	fail "$desc"
}
apk_file() { echo "/artifacts/$PKG${1:+-$1}-$PKG_FULLVERSION.apk"; }
install() { for p in "$@"; do apk_file "$p"; done | xargs apk add --allow-untrusted --no-network >/dev/null 2>&1; }

fetch() { wget -q -O - "$URL${1:+?$1}"; }
served() { fetch | grep -q "^node_scrape_collector_success{collector=\"$1\"} 1$"; }
not_served() { fetch >/tmp/m && ! grep -q "collector=\"$1\"" /tmp/m; }
metric() { fetch | grep -q "^$1"; }
refused() { wget -O /dev/null "$URL?$1" 2>&1 | grep -q "HTTP error 400"; }

instance() { ubus call service list "{\"name\":\"$NAME\"}"; }
# uhttpd's command line, on one line.
command_line() { instance | jsonfilter -e '@[*].instances.instance1.command[*]' | tr '\n' ' '; }
# The exporter's own instance; `watch` runs beside it while a path is missing.
pid() { instance | jsonfilter -e '@[*].instances.instance1.pid'; }
mounts() { instance | jsonfilter -e '@[*].instances.instance1.mount' | ucode -e 'print(join("\n", sort(keys(json(require("fs").stdin.read("all"))))), "\n")'; }
# What the init script mounts for the exporter's own code and libraries.
own_mount() { case $1 in /lib/libubus.so* | /lib/libuci.so* | /usr/lib/libnl* | /usr/lib/uhttpd_ucode.so | /usr/lib/ucode | \
	/usr/share/ucode/prometheus_exporter | $LIBEXEC/handler.uc) return 0 ;; esac; return 1; }
collector_mounts() { mounts | while read -r m; do own_mount "$m" || echo "$m"; done; }
mounts_match_jail() { [ "$(collector_mounts)" = "$($LIBEXEC/jail.uc 2>/dev/null)" ]; }
# What the jailed uhttpd sees of /etc/config: procd's pid is ujail's, which
# runs uhttpd as its child, in the jail's mount namespace.
jail_configs() { p=$(pid); ls "/proc/$(echo $(cat /proc/$p/task/$p/children))/root/etc/config"; }
restarted_from() { p=$(pid); [ -n "$p" ] && [ "$p" != "$1" ]; }
# uci set each of "$@", then commit and tell procd, as LuCI does.
set_config() { for a in "$@"; do uci set "$a"; done; uci commit && reload_config; }
jailed() { instance | jsonfilter -e '@[*].instances.instance1.jail.name' | grep -qx "$NAME"; }
not_mounted() { ! mounts | grep -qx "$1"; }
mounted() { mounts | grep -qx "$1"; }
# Whether the watch instance waits for path $1.
watching() { instance | jsonfilter -e '@[*].instances.watch.command[*]' | grep -qx "$1"; }
mount_moved() { mounts | grep -qx "$1" && not_mounted "$2"; }
fails() { ! "$@"; }
says() { pattern=$1; shift; "$@" 2>&1 | grep -q -- "$pattern"; }

# --- the system boots
eventually "procd, ubusd and netifd are up" ubus call network.interface.loopback status
reload_config # remembers the configs, so later changes fire config triggers

# What the collectors read, set up as a device would have it.
nft add table inet e2e && nft add counter inet e2e e2e_hits
ip link add e2e0 type veth peer name e2e1 && ip link set e2e0 up && ip link set e2e1 up
uci add dhcp host >/dev/null && uci set dhcp.@host[-1].name=e2e-host && uci set dhcp.@host[-1].mac=02:00:00:00:00:01 &&
	uci set dhcp.@host[-1].ip=192.168.1.201 && uci commit dhcp
# ubnt-manager reaches an airOS radio over ssh: here, this container's dropbear.
printf 'e2e\ne2e\n' | passwd root >/dev/null 2>&1
mkdir -p /usr/www && printf '#!/bin/sh\necho Content-Type: application/json\necho\necho %s\n' \
	'"{\"host\":{\"fwversion\":\"XC.v8.7.4\",\"uptime\":4242},\"wireless\":{\"count\":3}}"' >/usr/www/status.cgi &&
	chmod +x /usr/www/status.cgi
uci set ubnt-manager.sample_ap.target=127.0.0.1 && uci set ubnt-manager.sample_ap.username=root &&
	uci set ubnt-manager.sample_ap.password=e2e && uci commit ubnt-manager
reload_config

# A config the feed's ucode exporter left behind: apk keeps one someone changed
# when it removes the package.
OLD=/etc/config/prometheus-node-exporter-ucode
cat >"$OLD" <<'EOF'
config prometheus-node-exporter-ucode 'main'
	option listen_interface 'loopback'
	option listen_port '9101'
	option http_keepalive '30'

config collector 'wifi'
	option stations '0'
EOF
old_sum=$(md5sum <"$OLD")

# --- the base package
install ""
reload_config # remembers the exporter's config, new with the package
eventually "the base package starts the service" "$INIT" running
check "it takes over the old exporter's settings" test "$(uci -q get $NAME.main.http_keepalive) $(uci -q get $NAME.wifi.stations)" = "30 0"
check "but not its default port" test "$(uci -q get $NAME.main.listen_port)" = 9100
check "and serves with them" says ' -k 30 ' command_line
check "it leaves the old config as it was" test "$(md5sum <"$OLD")" = "$old_sum"
check "it logs what it took" says "imported from $OLD: http_keepalive=30, collector wifi" logread
check "its uci-defaults script runs once" test ! -e /etc/uci-defaults/$NAME-import
check "it makes no directory without textfile" test ! -e /var/prometheus
all_base_served() { for c in $BASE_COLLECTORS; do served "$c" || return 1; done; }
eventually "it serves every base collector" all_base_served
check "it runs in procd's jail" jailed
check "its mounts are what jail.uc prints" mounts_match_jail
check "the jail has its own config and no other" test "$(jail_configs)" = "$NAME"
check "no /etc/config/network in its mounts" not_mounted /etc/config/network

# --- the service's ubus object, which rpcd serves from the base package: no LuCI here
rpc() { ubus -t 30 call "$NAME" "$@"; }
rpc_collectors() { rpc collectors | jsonfilter -e '@.collectors[*].id' | wc -l; }
rpc_lists_all() { [ "$(rpc_collectors)" -eq "$(ls /usr/share/ucode/prometheus_exporter/collectors/*.uc | wc -l)" ]; }
# netifd's own interfaces, by name and protocol, and nothing else of them.
rpc_interfaces_are_netifds() {
	rpc interfaces >/tmp/interfaces.json && ubus call network.interface dump >/tmp/dump.json &&
	ucode -e "let fs = require('fs');
		let got = json(fs.readfile('/tmp/interfaces.json')).interfaces;
		let want = map(json(fs.readfile('/tmp/dump.json')).interface, (i) => ({ name: i.interface, proto: i.proto }));
		exit(length(want) > 0 && sprintf('%J', got) == sprintf('%J', want) ? 0 : 1);"
}
rpc_status_running() {
	rpc status >/tmp/status.json &&
	[ "$(jsonfilter -i /tmp/status.json -e '@.service.running')" = true ] &&
	jsonfilter -i /tmp/status.json -e '@.listen[*]' | grep -qx "$URL" &&
	[ "$(ucode -e "print(length(filter(json(require('fs').readfile('/tmp/status.json')).collectors, (c) => c.success)))")" \
		-eq "$(echo $BASE_COLLECTORS | wc -w)" ]
}
check "no LuCI app is installed" fails apk info -e "luci-app-$NAME"
eventually "rpcd serves the service's ubus object" rpc collectors
check "collectors lists every installed collector" rpc_lists_all
check "interfaces lists netifd's interfaces, by name and protocol" rpc_interfaces_are_netifds
check "status says it runs, where it listens, and scrapes every base collector" rpc_status_running
check "validate refuses what the init script would" says 'expected an integer from 1 to 65535, got 0' \
	rpc validate '{"main":{"listen_port":"0"}}'

# --- every collector package
before=$(pid)
COLLECTORS=$(ls /artifacts/$PKG-*-$PKG_FULLVERSION.apk | sed "s|^/artifacts/$PKG-||; s|-$PKG_FULLVERSION.apk$||")
install $COLLECTORS
eventually "installing collectors restarts the instance" restarted_from "$before"
installed() { ls /usr/share/ucode/prometheus_exporter/collectors/*.uc | wc -l; }
all_answer() { [ "$(fetch | grep -c '^node_scrape_collector_success{')" -eq "$(installed)" ]; }
eventually "every installed collector is served" all_answer
check "the ubus object lists the new collectors too" rpc_lists_all
check "its mounts are still what jail.uc prints" mounts_match_jail
check "the jail has the configs its collectors read" test "$(jail_configs | tr '\n' ' ')" = "dhcp network $NAME ubnt-manager "
check "the service makes textfile's directory" test -d /var/prometheus
check "and says so" says "made /var/prometheus" logread
check "and mounts it" mounted /var/prometheus
echo 'e2e_textfile_value 42' >/var/prometheus/e2e.prom
eventually "textfile reads its directory in the jail" metric 'e2e_textfile_value 42$'
check "nft-counters runs nft in the jail" served nft-counters
check "and reads the counters" metric 'nft_counter_packets_total{.*name="e2e_hits"'
check "ethtool runs ethtool in the jail" served ethtool
check "and reads a veth's statistics" metric 'node_ethtool_.*device="e2e0"'
check "uci_dhcp_host reads /etc/config/dhcp in the jail" metric 'node_openwrt_dhcp_host_info{name="e2e-host"'
check "modemmanager reaches ModemManager over D-Bus in the jail" served modemmanager
check "ubnt-manager's script runs in the jail, over ssh" metric 'ubnt_uptime_seconds{device="sample_ap"} 4242$'

# --- a program that hangs, in the jail
# A radio that takes ssh's connection and never says a word holds ssh as an
# unreachable one does: a socket listening, which accepts nothing. dbclient
# takes the port after the host.
succeeded_but() { grep '^node_scrape_collector_success{.*} 1$' | grep -v "collector=\"$1\"" | sort; }
left_behind() { ps w | grep -e 'ubnt-manager -j' -e '127.0.0.1/2222' | grep -v grep; }
ucode -e 'let s = require("socket").listen("127.0.0.1", 2222); sleep(600000);' &
silent=$!
others=$(fetch | succeeded_but ubnt-manager)
before=$(pid)
set_config "ubnt-manager.sample_ap.target=127.0.0.1/2222"
eventually "a radio that does not answer restarts the instance" restarted_from "$before"
before=$(pid)
started=$(date +%s)
fetch >/tmp/hung
took=$(($(date +%s) - started))
check "a scrape still answers" test -s /tmp/hung
check "after ubnt-manager's 5 seconds, not uhttpd's 60 ($took s)" test "$took" -ge 5 -a "$took" -lt 15
check "failing ubnt-manager" grep -qx 'node_scrape_collector_success{collector="ubnt-manager"} 0' /tmp/hung
check "and serving every other collector as before" test "$(succeeded_but ubnt-manager </tmp/hung)" = "$others"
check "it logs why" says "collector 'ubnt-manager': COMMAND_TIMEOUT (ubnt-manager: still running after 5 s, killed)" logread
sleep 1
check "and leaves neither the script nor its ssh behind" fails left_behind
check "the instance keeps running" test "$(pid)" = "$before"
kill $silent
set_config "ubnt-manager.sample_ap.target=127.0.0.1"
eventually "the radio that answers again is read again" metric 'ubnt_uptime_seconds{device="sample_ap"} 4242$'

# --- unbound, jailed, against a real unbound
# As at boot: the exporter starts before unbound has made /var/lib/unbound.
check "unbound has not made its directory yet" test ! -e /var/lib/unbound
check "so the jail leaves its socket directory out" not_mounted /var/lib/unbound
check "and the watch instance waits for it" watching /var/lib/unbound
check "check says the jail waits for it" says 'warn jail: unbound: /var/lib/unbound is not there; the service mounts it once it is' "$INIT" check
# Its control socket where the collector looks by default, on a port of its own
# (dnsmasq has 53).
uci set unbound.ub_main.listen_port=5353 && uci commit unbound
printf 'remote-control:\n\tcontrol-enable: yes\n\tcontrol-interface: /var/lib/unbound/unbound.ctl\n' >/etc/unbound/unbound_ext.conf
before=$(pid)
/etc/init.d/unbound start >/dev/null 2>&1
eventually "unbound makes its control socket" test -S /var/lib/unbound/unbound.ctl
eventually "the service mounts the directory once it is there" mounted /var/lib/unbound
check "restarting the exporter" restarted_from "$before"
eventually "unbound's collector reads its stats in the jail" served unbound
check "and writes them" metric 'unbound_queries_total{thread="0"} '
check "the watch instance no longer waits for it" fails watching /var/lib/unbound
before=$(pid)
/etc/init.d/unbound restart >/dev/null 2>&1
eventually "a restarted unbound's new socket is read in the same jail" served unbound
check "without restarting the exporter" test "$(pid)" = "$before"

# --- the config
before=$(pid)
set_config "$NAME.uname=collector" "$NAME.uname.enabled=0"
eventually "disabling a collector reloads the service" restarted_from "$before"
eventually "a disabled collector is not served" not_served uname
check "naming a disabled collector is a 400" refused 'collect[]=uname'

set_config "$NAME.textfile=collector" "$NAME.textfile.directory=/srv/e2e-prom"
eventually "textfile's directory moves its mount" mount_moved /srv/e2e-prom /var/prometheus
check "the service makes the new one, and its parent" test -d /srv/e2e-prom
echo 'e2e_moved_value 7' >/srv/e2e-prom/e2e.prom
eventually "textfile reads its new directory" metric 'e2e_moved_value 7$'
set_config "$NAME.textfile.enabled=0" "$NAME.textfile.directory=/srv/e2e-off"
eventually "a disabled textfile is not served" not_served textfile
check "nor its directory made" test ! -e /srv/e2e-off
set_config "$NAME.textfile.enabled=1" "$NAME.textfile.directory=/srv/e2e-prom"
eventually "enabled again, it is served" served textfile

before=$(pid)
set_config "$NAME.main.listen_port=http"
sleep 3
check "an invalid config keeps the running instance" test "$(pid)" = "$before"
check "which still serves" served loadavg
check "check fails on it" fails "$INIT" check
check "check says why" says 'FAIL main: CONFIG_INVALID (listen_port: expected an integer, got "http")' "$INIT" check
check "the reload logged why" says 'invalid configuration, keeping the running instance' logread
set_config "$NAME.main.listen_port=9100"

# --- removing a package
# ltq-dsl is in no group, which would keep it installed.
apk del "$PKG-ltq-dsl" >/dev/null 2>&1
eventually "a removed collector is not served" not_served ltq-dsl

# --- the service commands
check "check passes" "$INIT" check
check "check lists the collectors" says "^  textfile (Text files): section 'textfile', enabled" "$INIT" check
check "and the jail's mounts" says '^jail mounts:' "$INIT" check
serving=$(($(installed) - 1))
check "status says where it listens and what it serves" \
	says "^listening on http://127.0.0.1:9100/metrics, serving $serving collectors$" "$INIT" status
check "info shows the jail" says '"jail"' "$INIT" info
set_config "$NAME.main.enabled=0"
eventually "disabling the service stops it" fails "$INIT" running
check "status says it is disabled" says '^disabled' "$INIT" status
set_config "$NAME.main.enabled=1"
eventually "enabling it starts it again" served loadavg

if [ "$failures" -gt 0 ]; then
	echo "--- service"; instance
	echo "--- check"; "$INIT" check
	echo "--- log"; logread | grep -e "$NAME" -e uhttpd | tail -40
fi
echo "$failures failure(s)"
exit $((failures > 0))
