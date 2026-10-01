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
own_mount() { case $1 in /lib/libubus.so* | /lib/libuci.so* | /usr/lib/libnl* | /usr/lib/libz.so* | /usr/lib/uhttpd_ucode.so | /usr/lib/ucode | \
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
# A reply's head and body, by hand: wget hides the headers. HTTP/1.0, so uhttpd
# closes the connection once it has answered.
raw() { { printf 'GET /metrics?collect[]=loadavg HTTP/1.0\r\n%b\r\n' "$1"; sleep 2; } | nc 127.0.0.1 9100 >/tmp/raw; }
head_of() { sed -n '1,/^\r$/p' /tmp/raw | tr -d '\r'; }
body_of() { sed '1,/^\r$/d' /tmp/raw; }
varies() { head_of | grep -qx 'Vary: Accept-Encoding'; }
gzip_reply() { raw 'Accept-Encoding: gzip, deflate\r\n' && head_of | grep -qx 'Content-Encoding: gzip' && varies &&
	body_of | gzip -dc | grep -q '^node_load1 '; }
plain_reply() { raw "$1" && ! head_of | grep -qi '^Content-Encoding' && body_of | grep -q '^node_load1 '; }

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
check "it logs what it took, at info" says "daemon.info $NAME: imported from $OLD: http_keepalive=30, collector wifi" logread
check "its uci-defaults script runs once" test ! -e /etc/uci-defaults/$NAME-import
check "it makes no directory without textfile" test ! -e /var/prometheus
all_base_served() { for c in $BASE_COLLECTORS; do served "$c" || return 1; done; }
eventually "it serves every base collector" all_base_served
check "and gzips a scrape asked for it, its jail giving zlib's library" gzip_reply
check "it logs how many it serves at info" says "daemon.info $NAME\[[0-9]*\]: serving [0-9]* collectors, gzip when asked$" logread
check "and none of that at err" fails says "daemon.err.*serving [0-9]* collectors" logread
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
check "and says so, at info" says "daemon.info $NAME: made /var/prometheus$" logread
check "and mounts it" mounted /var/prometheus
echo 'e2e_textfile_value 42' >/var/prometheus/e2e.prom
eventually "textfile reads its directory in the jail" metric 'e2e_textfile_value 42$'
check "nft-counters runs nft in the jail" served nft-counters
check "and reads the counters" metric 'nft_counter_packets_total{.*name="e2e_hits"'

# What exec's watchdog costs a program: the mean milliseconds of a program's
# run by a plain popen (itself a shell running it) and through the watchdog
# (deps.exec_script); for nft, and for ethtool failing on a link with no
# statistics, as on a router's virtual links. Then of nft-counters (one run of
# nft, its JSON parsed) in a scrape, outside the jail (the command line) and in
# it (uhttpd). Printed, and checked loosely.
RUNS=20
popen_ms() {
	ucode -e "import { popen } from 'fs';
		import { exec_script, shell_quote } from 'prometheus_exporter.deps';
		let run = (cmd) => { let p = popen(cmd, 'r'); p.read('all'); p.close(); };
		let mean = function(f) {
			let t = clock(true);
			for (let i = 0; i < $RUNS; i++) f();
			let u = clock(true);
			return ((u[0] - t[0]) * 1000 + (u[1] - t[1]) / 1000000.0) / $RUNS;
		};
		let plain = join(' ', map(ARGV, shell_quote)) + ' 2>/dev/null';
		printf('%.1f %.1f\\n', mean(() => run(plain)), mean(() => run(exec_script(ARGV, 5))));" "$@"
}
duration_ms() { grep '^node_scrape_collector_duration_seconds{collector="nft-counters"}' | awk '{ s += $2 * 1000 } END { printf "%.1f\n", s / NR }'; }
set -- $(popen_ms nft --json list counters) $(popen_ms ethtool -S e2e0)
outside=$(i=0; while [ $i -lt $RUNS ]; do $NAME nft-counters; i=$((i + 1)); done | duration_ms)
inside=$(i=0; while [ $i -lt $RUNS ]; do fetch 'collect[]=nft-counters'; i=$((i + 1)); done | duration_ms)
echo "info mean of $RUNS runs: nft $1 ms by popen, $2 ms through the watchdog;" \
	"ethtool -S on a veth $3 ms by popen, $4 ms through the watchdog;" \
	"nft-counters in a scrape $outside ms outside the jail, $inside ms in it"
check "the watchdog adds less than 20 ms to a program (nft: $1 -> $2 ms)" awk "BEGIN { exit !($2 - $1 < 20) }"
# No device backs a link here (no /sys/class/net/<link>/device): ethtool asks none.
check "ethtool is served" served ethtool
check "and asks no link a device does not back, as a veth" fails metric 'node_ethtool_.*device="e2e0"'
check "uci_dhcp_host reads /etc/config/dhcp in the jail" metric 'node_openwrt_dhcp_host_info{name="e2e-host"'
# CAKE on the veth, as SQM would put it on a WAN, where the host's kernel has
# sch_cake; else fq_codel, which every kernel OpenWrt runs on has.
if tc qdisc replace dev e2e0 root cake bandwidth 10mbit besteffort >/dev/null 2>&1; then e2e_qdisc=cake; else
	tc qdisc replace dev e2e0 root fq_codel; e2e_qdisc=fq_codel; fi
echo "info the veth's root qdisc: $e2e_qdisc"
check "qdisc runs tc in the jail" served qdisc
check "and reads the veth's root $e2e_qdisc" metric "node_qdisc_packets_total{device=\"e2e0\",kind=\"$e2e_qdisc\"} "
check "but not the noqueue of the loopback" fails metric 'node_qdisc_[a-z_]*{device="lo"'
[ "$e2e_qdisc" = fq_codel ] || check "and CAKE's tin" metric 'node_qdisc_cake_tin_peak_delay_seconds{device="e2e0",tin="0"} '
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
check "it logs why, at warning" \
	says "daemon.warn $NAME\[[0-9]*\]: collector 'ubnt-manager': COMMAND_TIMEOUT (ubnt-manager: still running after 5 s, killed)" logread
sleep 1
check "and leaves neither the script nor its ssh behind" fails left_behind
check "the instance keeps running" test "$(pid)" = "$before"
# The seconds, set through uci as LuCI sets them: the main section's
# exec_timeout, then the collector's own timeout over it.
hung_for() { started=$(date +%s); fetch >/tmp/hung; echo $(($(date +%s) - started)); }
set_config "$NAME.main.exec_timeout=3"
eventually "setting exec_timeout restarts the instance" restarted_from "$before"
took=$(hung_for)
check "ubnt-manager then gets exec_timeout's 3 seconds ($took s)" test "$took" -ge 3 -a "$took" -lt 5
check "and says so" says "COMMAND_TIMEOUT (ubnt-manager: still running after 3 s, killed)" logread
before=$(pid)
set_config "$NAME.ubnt_manager=collector" "$NAME.ubnt_manager.timeout=1"
eventually "setting its timeout restarts the instance" restarted_from "$before"
took=$(hung_for)
check "ubnt-manager then gets its own 1 second over exec_timeout's 3 ($took s)" test "$took" -ge 1 -a "$took" -lt 3
check "and says so" says "COMMAND_TIMEOUT (ubnt-manager: still running after 1 s, killed)" logread
check "check says where its seconds come from" says "timeout  1s # its section's option timeout" "$INIT" check
check "a timeout out of range fails check" says \
	"FAIL collector ubnt-manager, section 'ubnt_manager': CONFIG_INVALID (timeout: expected an integer from 1 to 30, got 31)" \
	sh -c "uci set $NAME.ubnt_manager.timeout=31 && uci commit $NAME && $INIT check; uci set $NAME.ubnt_manager.timeout=1 && uci commit $NAME"
uci delete "$NAME.ubnt_manager"
set_config "$NAME.main.exec_timeout=5"
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
check "the reload logged why, at err" says "daemon.err $NAME: invalid configuration, keeping the running instance" logread
set_config "$NAME.main.listen_port=9100"

# --- gzip
check "a scrape asked for gzip is gzipped, and says so" gzip_reply
check "one not asked for it is plain" plain_reply ''
check "and says it varies by Accept-Encoding" varies
check "one that refuses gzip (gzip;q=0) is plain" plain_reply 'Accept-Encoding: gzip;q=0, identity\r\n'
# What gzip saves of a whole scrape, every collector installed: its size, and the
# mean milliseconds of a scrape, each way.
scrape_ms() {
	ucode -e "import { popen } from 'fs';
		let t = clock(true), n = 0;
		for (let i = 0; i < $RUNS; i++) { let p = popen(ARGV[0], 'r'); n = length(p.read('all')); p.close(); }
		let u = clock(true);
		printf('%d %.1f\\n', n, ((u[0] - t[0]) * 1000 + (u[1] - t[1]) / 1000000.0) / $RUNS);" "$1"
}
set -- $(scrape_ms "wget -q -O - $URL") $(scrape_ms "wget -q -O - --header='Accept-Encoding: gzip' $URL")
echo "info a whole scrape, mean of $RUNS: $1 bytes in $2 ms plain, $3 bytes in $4 ms gzipped"
check "gzip makes a whole scrape at least 5 times smaller ($1 -> $3 bytes)" test "$(($1 / $3))" -ge 5
before=$(pid)
set_config "$NAME.main.compress=0"
eventually "compress 0 restarts the instance" restarted_from "$before"
check "then a scrape asked for gzip is plain" plain_reply 'Accept-Encoding: gzip\r\n'
check "and does not say it varies" fails varies
check "check says so" says 'no compression (option compress)' "$INIT" check
set_config "$NAME.main.compress=1"
eventually "compress 1 gzips again" gzip_reply

# --- basic auth, over HTTPS only
# A self-signed certificate, as uhttpd's own init script makes one.
CERT=/etc/e2e.crt KEY=/etc/e2e.key HTTPS=https://127.0.0.1:9100/metrics AUTH_FILE=/var/run/$NAME/uhttpd.conf
px5g selfsigned -days 30 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout $KEY -out $CERT -subj /CN=127.0.0.1 >/dev/null 2>&1
HASH=$(rpc hash_password '{"password":"e2e-secret"}' | jsonfilter -e '@.hash')
sha512_crypt() { echo "$HASH" | grep -q '^\$6\$rounds=1000\$'; }
check "the ubus object hashes a password, as SHA-512-crypt" sha512_crypt
https() { uclient-fetch -q -O - --no-check-certificate "$@" "$HTTPS"; }
status_of() { uclient-fetch -O /dev/null --no-check-certificate "$@" "$HTTPS" 2>&1 | grep -o 'HTTP error [0-9]*'; }
unauthorized() { [ "$(status_of "$@")" = 'HTTP error 401' ]; }
logs_in() { https --user=prom --password=e2e-secret | grep -q '^node_load1 '; }
https_gzip() { https --user=prom --password=e2e-secret --header='Accept-Encoding: gzip' | gzip -dc | grep -q '^node_load1 '; }
no_hash_in() { ! "$@" 2>&1 | grep -qF "$HASH"; }
secret_free() { rpc status; rpc collectors; "$INIT" check; "$INIT" status; logread; }
auth_true() { rpc status | jsonfilter -e '@.service.auth' | grep -qx true; }
private() { ls -l "$AUTH_FILE" | grep -q '^-rw------- ' && ls -ld "/var/run/$NAME" | grep -q '^drwx------ '; }

before=$(pid)
set_config "$NAME.main.auth_user=prom" "$NAME.main.auth_password=$HASH"
sleep 3
check "basic auth without cert and key keeps the running instance" test "$(pid)" = "$before"
check "which still serves HTTP, without basic auth" served loadavg
check "check fails on it" fails "$INIT" check
check "and says why" says 'FAIL main: CONFIG_INVALID (auth_user: basic auth needs HTTPS: set cert and key, or the password crosses the network in the clear)' "$INIT" check
check "the reload logged why, at err" says "daemon.err $NAME: .*auth_user: basic auth needs HTTPS" logread
"$INIT" stop
"$INIT" start
check "start refuses it" fails "$INIT" running
check "and logs why" says "daemon.err $NAME: invalid configuration, not starting" logread
check "neither wrote basic auth's file" test ! -e "$AUTH_FILE"
check "validate refuses it" says 'basic auth needs HTTPS' rpc validate "{\"main\":{\"auth_user\":\"prom\",\"auth_password\":\"$HASH\"}}"

set_config "$NAME.main.cert=$CERT" "$NAME.main.key=$KEY"
eventually "with cert and key it starts, over HTTPS" logs_in
check "uhttpd reads basic auth's file" says " -c $AUTH_FILE " command_line
check "with its realm" says " -r $NAME " command_line
check "and listens on HTTPS alone" fails says ' -p ' command_line
check "the file is uhttpd's line for /metrics" test "$(cat "$AUTH_FILE")" = "/metrics:prom:$HASH"
check "mode 0600, in a directory of mode 0700" private
check "the jail mounts it" mounted "$AUTH_FILE"
check "a scrape without credentials is a 401" unauthorized
check "and with a wrong password" unauthorized --user=prom --password=wrong
check "and with a wrong user" unauthorized --user=other --password=e2e-secret
check "and with the hash as the password" unauthorized --user=prom "--password=$HASH"
check "the right ones scrape" logs_in
check "gzipped too, when asked" https_gzip
check "plain HTTP is not served" fails wget -q -O /dev/null "$URL"
check "check says basic auth is on, and for whom" says 'ok   main: HTTPS on interface loopback, port 9100, .*basic auth as user "prom"' "$INIT" check
check "status says it" says '^listening on https://127.0.0.1:9100/metrics, basic auth, gzip when asked, serving' "$INIT" status
check "so does the ubus object's status" auth_true
check "the hash is in no reply of the ubus object, nor in check, status or the log" no_hash_in secret_free
# What uhttpd -m prints, an unsalted MD5-crypt hash, works too.
set_config "$NAME.main.auth_password=$(uhttpd -m e2e-md5)"
md5_logs_in() { https --user=prom --password=e2e-md5 | grep -q '^node_load1 '; }
eventually "a hash of uhttpd -m takes its password" md5_logs_in
check "and no other" unauthorized --user=prom --password=e2e-secret
# What basic auth costs a scrape: the mean milliseconds of one of loadavg alone,
# with the hash hash_password makes ($6$, 1000 rounds), then without basic auth.
# The credentials go with the request, as Prometheus sends them: --user waits
# for a 401 first.
set_config "$NAME.main.auth_password=$HASH"
eventually "back to the hash hash_password made" logs_in
CREDENTIALS=$(ucode -e 'print(b64enc("prom:e2e-secret"))')
auth_ms=$(scrape_ms "uclient-fetch -q -O - --no-check-certificate --header='Authorization: Basic $CREDENTIALS' $HTTPS?collect[]=loadavg" | cut -d' ' -f2)
uci delete "$NAME.main.auth_user" && uci delete "$NAME.main.auth_password"
set_config
https_open() { https | grep -q '^node_load1 '; }
eventually "without basic auth it serves without credentials, still over HTTPS" https_open
check "and removes basic auth's file" test ! -e "$AUTH_FILE"
check "nor gives uhttpd one" says ' -c /dev/null ' command_line
plain_ms=$(scrape_ms "uclient-fetch -q -O - --no-check-certificate $HTTPS?collect[]=loadavg" | cut -d' ' -f2)
echo "info a scrape of loadavg over HTTPS, mean of $RUNS: $plain_ms ms, $auth_ms ms with basic auth"
# The check alone, in ucode, by the hash: what each format costs a scrape.
verify_ms() {
	ucode -e "import { verify, sha_crypt, md5_crypt } from 'prometheus_exporter.crypt';
		let mean = function(h) {
			let t = clock(true);
			for (let i = 0; i < $RUNS; i++) verify('e2e-secret', h);
			let u = clock(true);
			return ((u[0] - t[0]) * 1000 + (u[1] - t[1]) / 1000000.0) / $RUNS;
		};
		printf('%.1f %.1f %.1f\\n', mean(md5_crypt('e2e-secret', 'saltsalt')),
			mean(sha_crypt('6', 'e2e-secret', 'saltsaltsaltsalt', 1000)), mean(sha_crypt('6', 'e2e-secret', 'saltsaltsaltsalt', null)));"
}
set -- $(verify_ms)
echo "info checking a password, mean of $RUNS: $1 ms for \$1\$, $2 ms for \$6\$ of 1000 rounds, $3 ms for \$6\$ of 5000"
uci delete "$NAME.main.cert" && uci delete "$NAME.main.key"
set_config
eventually "without cert and key it serves HTTP again" served loadavg

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
	says "^listening on http://127.0.0.1:9100/metrics, gzip when asked, serving $serving collectors$" "$INIT" status
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
