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
# The exporter's state, which the jail mounts read-write (prometheus_exporter.state).
STATE=/var/run/$NAME/state
# Where the packages put the collectors.
COLLECTORS_DIR=/usr/share/ucode/prometheus_exporter/collectors
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
# The ubus socket, which procd's jail option mounts when a collector needs ubus:
# jail.uc names it, and procd lists no mount of it.
UBUS_SOCKET=/var/run/ubus/ubus.sock
# What jail.uc prints, its globs expanded as the init script's shell expands
# them, but the ubus socket, is every read-only mount of the instance: the
# state is its read-write one.
jail_paths() { for m in $($LIBEXEC/jail.uc 2>/dev/null | grep -vx "$UBUS_SOCKET"); do echo "$m"; done | sort -u; }
mounts_match_jail() { [ "$(mounts | grep -vx "$STATE")" = "$(jail_paths)" ]; }
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
uci set $NAME.main.http_keepalive=0 && uci commit $NAME && "$INIT" reload
eventually "keep-alive 0 has uhttpd close each connection" says ' -k 0 ' command_line
uci set $NAME.main.http_keepalive=30 && uci commit $NAME && "$INIT" reload
eventually "and back at 30, keeps it 30 seconds" says ' -k 30 ' command_line
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
# Its priority, and the data each of its processes may take: the uhttpd
# procd started in the jail, the child of the instance's ujail.
uhttpd_of() { cat /proc/$(pid)/task/*/children | tr ' ' '\n' | grep . | head -1; }
check "it runs at nice 10" test "$(cut -d' ' -f19 /proc/$(uhttpd_of)/stat)" = 10
check "its processes may take 64 MB of data at most" grep -q '^Max data size *67108864 *67108864 *bytes' /proc/$(uhttpd_of)/limits
check "its mounts are what jail.uc prints" mounts_match_jail
check "the jail has its own config and no other" test "$(jail_configs)" = "$NAME"
check "no /etc/config/network in its mounts" not_mounted /etc/config/network

# --- ubus, in the jail only while an enabled collector needs it
# Of the base collectors, timesync and openwrt_interfaces need it. The jail's
# root is that of the uhttpd it runs.
in_jail() { test -e "/proc/$(uhttpd_of)/root$1"; }
jailed_status() { ubus -t 30 call "$NAME" status | jsonfilter -e '@.jailed' | grep -qx true; }
check "the base collectors that need ubus have its socket in the jail" in_jail "$UBUS_SOCKET"
check "and jail.uc names it" says "^$UBUS_SOCKET$" "$LIBEXEC/jail.uc"
before=$(pid)
set_config "$NAME.timesync=collector" "$NAME.timesync.enabled=0" "$NAME.openwrt_interfaces=collector" "$NAME.openwrt_interfaces.enabled=0"
eventually "disabling them restarts the instance" restarted_from "$before"
eventually "which serves the rest" served loadavg
check "without the ubus socket in its jail" fails in_jail "$UBUS_SOCKET"
check "nor in what jail.uc prints" fails says "^$UBUS_SOCKET$" "$LIBEXEC/jail.uc"
check "the exporter collector is served without it" served exporter
check "its mounts are still what jail.uc prints" mounts_match_jail
check "check scrapes in the jail without it" says "^ok   scrape, in the service's jail: " "$INIT" check
check "and so does the ubus object's status" jailed_status
before=$(pid)
uci delete "$NAME.timesync" && uci delete "$NAME.openwrt_interfaces"
set_config
eventually "enabling them again restarts the instance" restarted_from "$before"
eventually "which serves them" served timesync
check "with the ubus socket in its jail again" in_jail "$UBUS_SOCKET"

# --- what a scrape costs besides its collectors, as Prometheus gets it
# The collectors are compiled as one program: what they share, the collector
# API and the modules behind it, once, and ucode keeps a source open per
# module. A program a collector kept six each: for 16 collectors, 80 more.
served_count() { fetch | grep -c '^node_scrape_collector_success'; }
fds_of() { ls /proc/$(uhttpd_of)/fd | wc -l; }
check "its uhttpd keeps a descriptor per collector, and about 60 more" test "$(fds_of)" -le $(($(served_count) + 64))
# The median of five scrapes, less what their collectors took: some 15 ms
# here. A scrape that waited on a poll (the runner's, of 100 ms) on its way,
# or did per collector what it may do once, would pass 100 ms.
outside_ms() {
	ucode -e '
		import { readfile } from "fs";
		let outside = [];
		for (let i = 0; i < 5; i++) {
			let t0 = clock(true);
			system("wget -q -O /tmp/scrape http://127.0.0.1:9100/metrics");
			let t1 = clock(true), took = (t1[0] - t0[0]) * 1000 + (t1[1] - t0[1]) / 1000000.0;
			for (let l in split(readfile("/tmp/scrape") ?? "", "\n")) {
				let m = match(l, /^node_scrape_collector_duration_seconds\{[^}]*\} (.*)$/);
				if (m)
					took -= +m[1] * 1000;
			}
			push(outside, took);
		}
		print(int(sort(outside, (a, b) => a - b)[2]), "\n");'
}
outside=$(outside_ms)
echo "     a scrape of the base collectors: ${outside} ms besides its collectors"
check "a scrape takes less than 100 ms besides its collectors" test "$outside" -lt 100

# --- timesync: busybox ntpd's events, kept by the base package's hotplug script
# ntpd runs here, unsynchronized (no network), and reports every 11 minutes:
# its events are made as it makes them, by its own hotplug script, with the
# environment busybox gives it, through procd's hotplug.ntp. A real event may
# come between, so each is made again until it is read.
NTPD_STATE=/var/run/$NAME/timesync/ntpd
ntpd_event() { action=$1; shift; env "$@" /usr/sbin/ntpd-hotplug "$action" >/dev/null 2>&1; }
synced() { ntpd_event stratum stratum=2 offset=0.001234 freq_drift_ppm=12 poll_interval=64 &&
	metric 'node_timesync_synchronized{daemon="ntpd"} 1$' && metric 'node_timesync_stratum{daemon="ntpd"} 2$' &&
	metric 'node_timesync_offset_seconds{daemon="ntpd"} 0.001234$'; }
unsynced() { ntpd_event unsync stratum=16 offset=0.000000 freq_drift_ppm=12 poll_interval=64 &&
	metric 'node_timesync_synchronized{daemon="ntpd"} 0$' && fails metric 'node_timesync_stratum'; }
check "the service makes timesync's directory" test -d "${NTPD_STATE%/*}"
check "and mounts it" mounted "${NTPD_STATE%/*}"
check "timesync is served with busybox ntpd running" served timesync
eventually "busybox ntpd's event, through hotplug.ntp, says it is synchronized, in the jail" synced
check "the hotplug script keeps it, written whole" grep -qx 'action=stratum' "$NTPD_STATE"
# A real ntpd event may be writing its own at that moment.
eventually "and leaves no temporary file" test "$(ls "${NTPD_STATE%/*}")" = ntpd
ubus call hotplug.ntp call '{"env":["ACTION=stratum"]}'; sleep 1
check "chrony's own event, without busybox's environment, is not kept" grep -qx 'stratum=2' "$NTPD_STATE"
eventually "losing sync, it is not" unsynced

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
check "validate says what is wrong by its code" says '"code": "RANGE"' \
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
check "the jail has the configs its collectors read" test "$(jail_configs | tr '\n' ' ')" = "chrony dhcp $NAME ubnt-manager "
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
# nft, its JSON parsed) in a scrape, by the command line (in the jail too,
# by ujail) and by uhttpd. Printed, and checked loosely.
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
outside=$(i=0; while [ $i -lt $RUNS ]; do $NAME scrape nft-counters; i=$((i + 1)); done | duration_ms)
inside=$(i=0; while [ $i -lt $RUNS ]; do fetch 'collect[]=nft-counters'; i=$((i + 1)); done | duration_ms)
echo "info mean of $RUNS runs: nft $1 ms by popen, $2 ms through the watchdog;" \
	"ethtool -S on a veth $3 ms by popen, $4 ms through the watchdog;" \
	"nft-counters in a scrape $outside ms by the command line, $inside ms by uhttpd"
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

# --- nothing to observe: hardware that is not there, a service disabled
# A success without samples, observing 0, that the scrape does not log, and
# that check and the ubus object's status say, with why.
observing() { metric "node_scrape_collector_observing{collector=\"$1\"} $2$"; }
reason() { rpc status | jsonfilter -e "@.collectors[@.name='$1'].reason"; }
is_reason() { [ "$(reason "$1")" = "$2" ]; }
logged() { logread | grep -c "collector '$1'"; }
check "wifi, without a radio here, succeeds" served wifi
check "with nothing to observe" observing wifi 0
check "and writes no sample" fails metric 'node_wifi_'
check "check says why" says '^ok   scrape: wifi has nothing to observe: no wireless radios$' "$INIT" check
check "and so does the ubus object's status" is_reason wifi 'no wireless radios'
check "modemmanager asks ModemManager, which lists no modem" says '^ok   scrape: modemmanager has nothing to observe: ModemManager lists no modems$' "$INIT" check

# --- diskstats, sockstat and hwmon: the host's kernel, read in the jail
# /proc/diskstats and /sys are the host's: whether there is a disk to observe
# is what device_exclude leaves of the host's block devices.
DISK_EXCLUDE=$(ucode -e "import { DEFAULT_EXCLUDE } from 'prometheus_exporter.collectors.diskstats'; print(DEFAULT_EXCLUDE);")
disk=$(awk 'NF >= 14 { print $3 }' /proc/diskstats | grep -Ev "$DISK_EXCLUDE" | head -1)
echo "info the host's first disk diskstats keeps: ${disk:-none}"
check "diskstats is served" served diskstats
if [ -n "$disk" ]; then
	check "and reads /proc/diskstats in the jail ($disk)" metric "node_disk_written_bytes_total{device=\"$disk\"} "
	check "and /sys/block, whether it is rotational" metric "node_disk_info{device=\"$disk\",major=\"[0-9]*\",minor=\"[0-9]*\",rotational=\"[01]\"} 1$"
else
	check "with nothing to observe" observing diskstats 0
fi
before=$(pid)
set_config "$NAME.diskstats=collector" "$NAME.diskstats.device_exclude=."
eventually "a device_exclude of every device restarts the instance" restarted_from "$before"
check "and diskstats has nothing to observe" observing diskstats 0
check "check says why" says '^ok   scrape: diskstats has nothing to observe: device_exclude leaves out every block device$' "$INIT" check
before=$(pid)
uci delete "$NAME.diskstats"
set_config
eventually "its default again restarts the instance" restarted_from "$before"
eventually "sockstat reads /proc/net/sockstat in the jail" metric 'node_sockstat_TCP_inuse '
check "and the page size, from /proc/self/auxv" metric 'node_sockstat_TCP_mem_bytes '
[ ! -e /proc/net/sockstat6 ] || check "and /proc/net/sockstat6" metric 'node_sockstat_TCP6_inuse '
# A sensor the host's driver answers now: one asleep (a GPU's) answers nothing,
# and hwmon leaves it out.
host_reads() { for f in /sys/class/hwmon/*/$1; do cat "$f" >/dev/null 2>&1 && return 0; done; return 1; }
! host_reads 'in[0-9]*_input' || eventually "hwmon reads the host's voltages in the jail" metric 'node_hwmon_in_volts{'
! host_reads 'fan[0-9]*_input' || eventually "and its fans" metric 'node_hwmon_fan_rpm{'
! host_reads 'curr[0-9]*_input' || eventually "and its currents" metric 'node_hwmon_curr_amps{'

check "dnsmasq runs, and is observed" observing dnsmasq 1
check "its metrics are written" metric 'dnsmasq_'
/etc/init.d/dnsmasq disable
/etc/init.d/dnsmasq stop
eventually "dnsmasq stopped and disabled succeeds" served dnsmasq
check "with nothing to observe, rpcd's rc reached from the jail" observing dnsmasq 0
check "and writes no sample" fails metric 'dnsmasq_'
before_logs=$(logged dnsmasq)
fetch >/dev/null; fetch >/dev/null
check "a scrape logs nothing of it" test "$(logged dnsmasq)" = "$before_logs"
check "check says why" says '^ok   scrape: dnsmasq has nothing to observe: dnsmasq is disabled$' "$INIT" check
check "and so does the ubus object's status" is_reason dnsmasq 'dnsmasq is disabled'
/etc/init.d/dnsmasq enable
failing_dnsmasq() { metric 'node_scrape_collector_success{collector="dnsmasq"} 0$'; }
eventually "enabled and still stopped, dnsmasq fails" failing_dnsmasq
check "observing it, and failing" observing dnsmasq 1
check "logged at warning" says "daemon.warn $NAME\[[0-9]*\]: collector 'dnsmasq': UBUS_CALL_FAILED (dnsmasq metrics: Not found" logread
check "check says why" says '^warn scrape: dnsmasq: UBUS_CALL_FAILED (dnsmasq metrics: Not found' "$INIT" check
check "and the ubus object's status gives no reason" is_reason dnsmasq ''
/etc/init.d/dnsmasq start
eventually "started again, dnsmasq is read again" metric 'dnsmasq_'
check "and succeeds" served dnsmasq

# --- chrony, and timesync's chronyd: a real chronyd, unsynchronized without a
# network. The image leaves it disabled (see the pkgcheck Dockerfile).
check "chronyd disabled, chrony has nothing to observe" observing chrony 0
check "check says why" says '^ok   scrape: chrony has nothing to observe: chronyd is disabled$' "$INIT" check
/etc/init.d/chronyd enable
/etc/init.d/chronyd start
eventually "chronyd starts" chronyc -c tracking
eventually "chrony reads chronyd in the jail" metric 'chrony_tracking_stratum 0$'
check "observing it" observing chrony 1
check "its tracking, unsynchronized" metric 'chrony_tracking_info{tracking_address="",tracking_name="",tracking_refid="00000000"} 1$'
check "but no serverstats in the jail, which gives chronyc no command socket" fails metric 'chrony_serverstats_'
check "nor in the command line's scrape, which runs in the service's jail too" fails says '^chrony_serverstats_' "$NAME" scrape chrony
check "timesync says chronyd is not synchronized, running chronyc in the jail" metric 'node_timesync_synchronized{daemon="chronyd"} 0$'
check "beside busybox ntpd" metric 'node_timesync_synchronized{daemon="ntpd"} '
/etc/init.d/chronyd stop
failing() { metric "node_scrape_collector_success{collector=\"$1\"} 0$"; }
eventually "enabled and stopped, chronyd fails chrony" failing chrony
# One scrape, before three failures in a row quarantine them.
fetch >/tmp/chrony_down
check "observing it" grep -qx 'node_scrape_collector_observing{collector="chrony"} 1' /tmp/chrony_down
check "logged at warning" says "daemon.warn $NAME\[[0-9]*\]: collector 'chrony': COMMAND_FAILED (chronyc: exit status 1)" logread
check "and timesync" grep -qx 'node_scrape_collector_success{collector="timesync"} 0' /tmp/chrony_down
check "which still says what busybox ntpd does" grep -q '^node_timesync_synchronized{daemon="ntpd"} ' /tmp/chrony_down
/etc/init.d/chronyd disable
eventually "disabled again, chrony has nothing to observe" observing chrony 0
eventually "and timesync observes busybox ntpd alone" served timesync
check "without chronyd" fails metric 'node_timesync_synchronized{daemon="chronyd"}'

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
before=$(pid)
uci delete "$NAME.ubnt_manager"
set_config "$NAME.main.exec_timeout=5"

# --- the scrape's deadline and the circuit breakers, in the jail
# The radio still does not answer: ubnt-manager's ssh hangs. Each restart
# starts the instance without a ledger, without durations or breakers.
deadline_fetch() { wget -q -O - --header="X-Prometheus-Scrape-Timeout-Seconds: $1" "$URL"; }
quarantined() { grep -qx "ucode_prometheus_exporter_collector_quarantined{collector=\"$1\"} 1" "$2"; }
check "uhttpd gives a scrape 60 seconds, as the exporter reckons" says ' -t 60 ' command_line
check "and runs 3 requests at once, over 10 connections at most" says ' -n 3 -N 10 ' command_line
eventually "exec_timeout 5 again restarts the instance" restarted_from "$before"
before=$(pid)
# Every other collector timed once: ubnt-manager, never run, runs after them.
fetch 'exclude[]=ubnt-manager' >/dev/null
started=$(date +%s)
deadline_fetch 3 >/tmp/late
took=$(($(date +%s) - started))
ubnt_ledger() { grep -o '"ubnt_manager": {[^}]*}' "$STATE"/*.scrape; }
echo "info a scrape of 3 s: $(grep 'ubnt-manager' /tmp/late | tr '\n' ' '); its ledger: $(ubnt_ledger)"
echo "info $(logread | grep 'scrape deadline' | tail -1)"
check "a scrape Prometheus gives 3 seconds answers within them ($took s)" test "$took" -le 3 -a -s /tmp/late
check "without ubnt-manager, its program killed at the deadline" grep -qx 'node_scrape_collector_success{collector="ubnt-manager"} 0' /tmp/late
check "serving every other collector as before" test "$(succeeded_but ubnt-manager </tmp/late)" = "$others"
check "and says so in one line, at warning" \
	says "daemon.warn $NAME\[[0-9]*\]: scrape deadline: 1 collector not served in its 2.5 s: ubnt-manager$" logread
check "not a line of the collector's own" fails says "collector 'ubnt-manager': SCRAPE_DEADLINE" logread
check "and does not quarantine it" fails quarantined ubnt-manager /tmp/late
# Without the header, scrape_timeout's 10 s: ubnt-manager's program runs its
# own 5 s, is killed, and trips its breaker.
fetch >/tmp/hung
echo "info then a scrape of 10 s: its ledger: $(ubnt_ledger)"
check "a program killed at its own timeout" says "COMMAND_TIMEOUT (ubnt-manager: still running after 5 s, killed)" logread
check "quarantines its collector for a scrape, which is logged" \
	says "daemon.warn $NAME\[[0-9]*\]: collector 'ubnt-manager' quarantined for 1 scrape: COMMAND_TIMEOUT" logread
# The next scrape, which names it.
started=$(date +%s)
fetch 'collect[]=ubnt-manager&collect[]=loadavg' >/tmp/held
took=$(($(date +%s) - started))
check "the next scrape leaves it out, at once, though it names it ($took s)" test "$took" -lt 2
check "saying it is quarantined" quarantined ubnt-manager /tmp/held
check "and that it failed" grep -qx 'node_scrape_collector_success{collector="ubnt-manager"} 0' /tmp/held
check "serving the others" grep -qx 'node_scrape_collector_success{collector="loadavg"} 1' /tmp/held
check "check says the service quarantined it, why, and when it tries again" \
	says '^warn service: ubnt-manager is quarantined: COMMAND_TIMEOUT (ubnt-manager: still running after 5 s, killed); the service tries it again' "$INIT" check
service_quarantined() { rpc status | jsonfilter -e "@.collectors[@.name='ubnt-manager'].service.quarantined" | grep -qx true; }
check "so does the ubus object's status" service_quarantined
check "the ledger is the instance's, in the state directory" test -s "$(ls "$STATE"/*.scrape)"
ledger=$(ls "$STATE"/*.scrape)
"$INIT" restart
eventually "a restart starts a new instance" restarted_from "$before"
eventually "which removes the ledger of the one before" test ! -e "$ledger"
check "check then says nothing of a quarantine" fails says 'service: ubnt-manager is quarantined' "$INIT" check
started=$(date +%s)
wget -q -O - "$URL?collect[]=ubnt-manager" >/tmp/fresh
took=$(($(date +%s) - started))
check "and ubnt-manager runs again, at its 5 s ($took s): a restart forgets the quarantine" test "$took" -ge 5
check "not quarantined" sh -c "grep -qx 'ucode_prometheus_exporter_collector_quarantined{collector=\"ubnt-manager\"} 0' /tmp/fresh"
# The exporter collector, in the jail: the serving uhttpd, and the new
# instance's counters, this scrape its second.
fetch >/tmp/self
check "the exporter collector describes the serving uhttpd in the jail: its descriptors" grep -q '^process_open_fds [1-9]' /tmp/self
check "its CPU, its memory, its start and its limit" sh -c "grep -q '^process_cpu_seconds_total ' /tmp/self && grep -q '^process_resident_memory_bytes [1-9]' /tmp/self &&
	grep -q '^process_start_time_seconds [1-9]' /tmp/self && grep -q '^process_max_fds [1-9]' /tmp/self"
check "and counts the scrapes of the instance since its restart" grep -qx 'ucode_prometheus_exporter_scrapes_total 2' /tmp/self
check "the quarantine of ubnt-manager, and its program killed" sh -c "grep -qx 'ucode_prometheus_exporter_quarantines_total{collector=\"ubnt-manager\"} 1' /tmp/self &&
	grep -qx 'ucode_prometheus_exporter_program_timeouts_total{collector=\"ubnt-manager\"} 1' /tmp/self &&
	grep -qx 'ucode_prometheus_exporter_collector_failures_total{collector=\"ubnt-manager\",reason=\"COMMAND_TIMEOUT\"} 1' /tmp/self"
check "and the samples of each collector of the scrape" grep -q '^ucode_prometheus_exporter_collector_samples{collector="cpu"} [1-9]' /tmp/self
kill $silent
set_config "ubnt-manager.sample_ap.target=127.0.0.1"
eventually "the radio that answers again is read again" metric 'ubnt_uptime_seconds{device="sample_ap"} 4242$'

# --- containment: collectors that break the contract
# Each is a module dropped where the packages put collectors, as a third
# party's package would, and each costs its own collector and nothing more:
# the rest of the scrape is served on time, and the culprit is named in the
# reply, logged, counted by the exporter collector and quarantined.
DIR=$COLLECTORS_DIR
broken() {
	name=$1 top=$2 meta=$3; shift 3
	cat >"$DIR/$name.uc" <<EOF
'use strict';
import { Result } from 'prometheus_exporter.api';
${IMPORT:+$IMPORT
}export const meta = { name: '$name', title: 'Broken on purpose', help: 'A collector that breaks the contract, for e2e.', needs: [ 'fs' ]$meta };
$top
export function collect(deps, out) {
	$*
	return Result.ok();
};
EOF
}
broken e2e_loop '' '' 'while (true) ;'
broken e2e_hang '' ", needs: [ 'exec' ], commands: [ 'sleep' ], timeout: 1" "return deps.exec.run([ 'sleep', '600' ]);"
broken e2e_flood '' '' "let g = out.gauge('e2e_flood_value'); for (let i = 0; ; i++) g({ i }, i);"
broken e2e_thief '' '' "out.gauge('node_load1', 'Not its own.')(null, 42);"
broken e2e_hog '' '' "let s = 'x'; while (true) s += s;"
broken e2e_stuck 'while (true) ;' '' ''
# A third party's module that imports fs, as ucode's own scripts do.
IMPORT="import { readfile } from 'fs';"
broken e2e_importer '' '' 'readfile("/etc/passwd");'
IMPORT=
mkfifo /var/prometheus/e2e-fifo.prom
# Stopped at 2 s rather than 5: the e2e waits less.
uci set $NAME.e2e_loop=collector && uci set $NAME.e2e_loop.budget=2 && uci commit $NAME
before=$(pid)
"$INIT" reload
eventually "installing broken collectors restarts the instance" restarted_from "$before"
eventually "which serves again" served loadavg
started=$(date +%s)
fetch >/tmp/broken
took=$(($(date +%s) - started))
echo "info a scrape with the broken collectors took $took s: $(grep -c '^node_scrape_collector_success{.*} 1$' /tmp/broken) collectors served"
failed() { grep -qx "node_scrape_collector_success{collector=\"$1\"} 0" "${2:-/tmp/broken}"; }
logged_as() { logread | grep -q "daemon.warn $NAME\[[0-9]*\]: collector '$1': $2"; }
check "a scrape still answers, in the scraper's time ($took s)" test -s /tmp/broken -a "$took" -lt 10
check "serving the other collectors" sh -c "grep -qx 'node_scrape_collector_success{collector=\"loadavg\"} 1' /tmp/broken &&
	grep -qx 'node_scrape_collector_success{collector=\"cpu\"} 1' /tmp/broken && grep -q '^node_load1 [0-9]' /tmp/broken"
check "one that never returns is stopped at its budget" failed e2e_loop
check "and logged as cancelled" logged_as e2e_loop 'COLLECTOR_CANCELLED (still running after 2.0[0-9] s, over its budget of 2 s: stopped)'
check "one whose program hangs fails at its timeout" failed e2e_hang
check "and logged" logged_as e2e_hang 'COMMAND_TIMEOUT (sleep: still running after 1 s, killed)'
check "one that writes far over the sample limit fails" failed e2e_flood
check "with none of its samples served" fails grep -q '^e2e_flood_value' /tmp/broken
check "and logged with how far it got" logged_as e2e_flood 'SAMPLE_LIMIT (more than its max_samples of 20000: stopped at 20001 samples, in e2e_flood_value)'
check "one that writes another's family fails" failed e2e_thief
check "the family staying the first's" fails grep -qx 'node_load1 42' /tmp/broken
check "and logged" logged_as e2e_thief 'FAMILY_CONFLICT (node_load1 belongs to collector loadavg)'
check "one that allocates past the memory limit costs its own process" failed e2e_hog
check "and logged as killed" logged_as e2e_hog 'COLLECTOR_KILLED (its process ended while it ran'
check "one that hangs when loaded is left out, logged at err" says "daemon.err $NAME\[[0-9]*\]: collector 'e2e_stuck' hung at load: still loading after 5 s: stopped; it is left out" logread
check "and is not served" fails grep -q 'collector="e2e_stuck"' /tmp/broken
check "one that imports fs is left out unloaded, logged at err with what to use" says "daemon.err $NAME\[[0-9]*\]: skipping collector: COLLECTOR_INVALID (e2e_importer: imports fs (line 3): a collector reads files through deps.fs, with 'fs' in meta.needs)" logread
check "and is not served" fails grep -q 'collector="e2e_importer"' /tmp/broken
check "a FIFO in textfile's directory does not hold it" grep -qx 'node_scrape_collector_success{collector="textfile"} 1' /tmp/broken
check "it is skipped and counted" grep -qx 'node_textfile_scrape_error 1' /tmp/broken
check "and logged" says "collector 'textfile': skipped /var/prometheus/e2e-fifo.prom: is not a regular file (fifo): not read" logread
# A breaker trips as soon as its collector fails as it does, and a trial
# after a quarantine trips it again: some scrape of the next ones says it.
quarantined_soon() { cat /tmp/broken2 /tmp/broken3 /tmp/broken4 | grep -qx "ucode_prometheus_exporter_collector_quarantined{collector=\"$1\"} 1"; }
fetch >/tmp/broken2; fetch >/tmp/broken3; fetch >/tmp/broken4
for c in e2e_loop e2e_hang e2e_hog e2e_flood e2e_thief; do
	check "$c is quarantined" quarantined_soon $c
	check "and its quarantine logged" says "daemon.warn $NAME\[[0-9]*\]: collector '$c' quarantined for [0-9]* scrape" logread
done
counted() { grep -qx "ucode_prometheus_exporter_collector_failures_total{collector=\"$1\",reason=\"$2\"} [1-9][0-9]*" /tmp/broken4; }
for t in e2e_loop:COLLECTOR_CANCELLED e2e_hang:COMMAND_TIMEOUT e2e_flood:SAMPLE_LIMIT e2e_thief:FAMILY_CONFLICT e2e_hog:COLLECTOR_KILLED; do
	check "and counts ${t%%:*}'s ${t#*:}" counted "${t%%:*}" "${t#*:}"
done
check "and every other collector is still served" test "$(grep -c '^node_scrape_collector_success{.*} 1$' /tmp/broken4)" -eq "$(grep -c '^node_scrape_collector_success{.*} 1$' /tmp/broken)"

# A scrape process killed while a collector runs (as uhttpd kills one past
# its -t, or the kernel's OOM killer would): the next scrape finds its
# progress file, names the collector it was running, quarantines it, and
# kills the child process it was running in, which nothing else stops.
broken e2e_slow '' '' 'while (true) ;'
uci set $NAME.e2e_slow=collector && uci set $NAME.e2e_slow.budget=30 && uci commit $NAME
before=$(pid)
"$INIT" reload
eventually "a collector that loops for 30 s restarts the instance" restarted_from "$before"
eventually "which serves" served loadavg
fetch 'collect[]=e2e_slow&collect[]=loadavg' >/dev/null 2>&1 &
# The scrape process of that request: a child of uhttpd (the child of the
# instance's ujail) with a child of its own.
children() { cat /proc/$1/task/*/children 2>/dev/null | tr ' ' '\n' | grep .; }
running() {
	for p in $(children "$(children "$(pid)" | head -1)"); do
		c=$(children "$p" | head -1)
		[ -n "$c" ] && { scrape_pid=$p child_pid=$c; return 0; }
	done
	return 1
}
eventually "the scrape runs its collector in a child process" running
echo "info the scrape process $scrape_pid ran e2e_slow in $child_pid; killing the scrape process"
kill -KILL "$scrape_pid"
sleep 1
check "the child is left running when its scrape process dies" test -d "/proc/$child_pid"
fetch >/tmp/after
check "the next scrape names the collector it was running" says "daemon.warn $NAME\[[0-9]*\]: collector 'e2e_slow' was running when a scrape process died" logread
check "quarantines it" grep -qx 'ucode_prometheus_exporter_collector_quarantined{collector="e2e_slow"} 1' /tmp/after
check "counts it as killed" grep -qx 'ucode_prometheus_exporter_collector_failures_total{collector="e2e_slow",reason="COLLECTOR_KILLED"} 1' /tmp/after
eventually "and kills the child left running" test ! -d "/proc/$child_pid"
check "leaving no progress file" test -z "$(ls "$STATE" | grep '\.p[0-9]*_[0-9]*$')"
grep -q 'ucode_prometheus_exporter_collector_quarantined{collector="e2e_slow"} 1' /tmp/after ||
	echo "info the scrape after: $(grep 'e2e_slow' /tmp/after | tr '\n' ' '); its state: $(ls "$STATE" | tr '\n' ' '); $(cat "$STATE"/*.p* 2>/dev/null | tr '\n' ' ')"

# The ubus object's status, with a collector that never returns: each run
# is stopped by its scrape's deadline, so a page refreshed again and again
# leaves no helper behind.
helpers() { ps w | grep -c -e '[r]pc-status.uc' -e '[t]rial.uc'; }
started=$(date +%s)
for i in 1 2 3; do ubus -t 60 call "$NAME" status >/tmp/status$i.json 2>/dev/null & sleep 1; done
most=0
while [ "$(helpers)" -gt 0 ] && [ $(($(date +%s) - started)) -lt 40 ]; do
	n=$(helpers); [ "$n" -le "$most" ] || most=$n
	sleep 1
done
wait
took=$(($(date +%s) - started))
echo "info three status calls 1 s apart, with e2e_slow looping: $took s, at most $most processes of theirs at once (helpers, ujail, their children)"
check "status helpers end within the scrape's time ($took s), none left" test "$(helpers)" -eq 0 -a "$took" -lt 25
check "each status call answered, scraping in the jail" sh -c 'for i in 1 2 3; do jsonfilter -i /tmp/status$i.json -e "@.jailed" | grep -qx true || exit 1; done'
check "saying e2e_slow failed" sh -c "jsonfilter -i /tmp/status1.json -e \"@.collectors[@.name='e2e_slow'].success\" | grep -qx false"

# Gone again.
rm -f "$DIR"/e2e_*.uc /var/prometheus/e2e-fifo.prom
uci delete "$NAME.e2e_loop" && uci delete "$NAME.e2e_slow" && uci commit "$NAME"
before=$(pid)
"$INIT" reload
eventually "removing the broken collectors restarts the instance" restarted_from "$before"
eventually "which serves every base collector" all_base_served

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

set_config "$NAME.textfile=collector" "$NAME.textfile.directory=/tmp/e2e/prom"
eventually "textfile's directory moves its mount" mount_moved /tmp/e2e/prom /var/prometheus
check "the service makes the new one, and its parent" test -d /tmp/e2e/prom
echo 'e2e_moved_value 7' >/tmp/e2e/prom/e2e.prom
eventually "textfile reads its new directory" metric 'e2e_moved_value 7$'
set_config "$NAME.textfile.enabled=0" "$NAME.textfile.directory=/tmp/e2e-off"
eventually "a disabled textfile is not served" not_served textfile
check "nor its directory made" test ! -e /tmp/e2e-off
# A directory with a trailing /, as its datatype takes it: the same one.
set_config "$NAME.textfile.enabled=1" "$NAME.textfile.directory=/tmp/e2e/prom/"
eventually "enabled again, it is served" served textfile
check "its directory named with a trailing / is mounted" mounted /tmp/e2e/prom
eventually "and read in the jail" metric 'e2e_moved_value 7$'
# The service makes and mounts its directory under /var, /tmp and
# /etc/prometheus-exporter alone.
before=$(pid)
set_config "$NAME.textfile.directory=/srv/e2e-prom"
sleep 3
check "a directory elsewhere keeps the running instance" test "$(pid)" = "$before"
check "which it neither makes" test ! -e /srv/e2e-prom
check "nor mounts" not_mounted /srv/e2e-prom
check "check says why" says 'directory: expected a directory under /var, /tmp or /etc/prometheus-exporter, which the service makes and mounts, got "/srv/e2e-prom"' "$INIT" check
check "and validate, by its code" says '"code": "OWNED_DIRECTORY"' rpc validate '{"collectors":{"textfile":{"directory":"/srv/e2e-prom"}}}'
set_config "$NAME.textfile.directory=/tmp/e2e/prom/"
eventually "back under /tmp, it is served" served textfile

before=$(pid)
set_config "$NAME.main.listen_port=http"
sleep 3
check "an invalid config keeps the running instance" test "$(pid)" = "$before"
check "which still serves" served loadavg
check "check fails on it" fails "$INIT" check
check "check says why" says 'FAIL main: CONFIG_INVALID (listen_port: expected an integer, got "http")' "$INIT" check
check "the reload logged why, at err" says "daemon.err $NAME: invalid configuration, keeping the running instance" logread
set_config "$NAME.main.listen_port=9100"

# memory_limit: under 8 MB uhttpd cannot load the handler, and would
# crash-loop; at 8 it loads every collector installed here.
before=$(pid)
set_config "$NAME.main.memory_limit=2"
sleep 3
check "a memory_limit the handler cannot load in keeps the running instance" test "$(pid)" = "$before"
check "check says why" says 'FAIL main: CONFIG_INVALID (memory_limit: expected 0, or an integer of 8 or more, got 2)' "$INIT" check
set_config "$NAME.main.memory_limit=8"
eventually "memory_limit 8 restarts the instance" restarted_from "$before"
enabled_answer() { [ "$(fetch | grep -c '^node_scrape_collector_success{')" -eq "$($NAME collector list | grep -c ' enabled ')" ]; }
eventually "which answers for every enabled collector" enabled_answer
check "and loaded them all" says "serving $(installed) collectors" sh -c "logread | grep 'daemon.info $NAME\[' | tail -1"
check "each of its processes may take 8 MB of data" grep -q '^Max data size *8388608 *8388608 *bytes' /proc/$(uhttpd_of)/limits
before=$(pid)
uci delete "$NAME.main.memory_limit"
set_config
eventually "unset, a quarter of the RAM again restarts it" restarted_from "$before"
eventually "which serves" served loadavg

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
# A renewed certificate, as acme writes one: new files at the same paths. The
# jail holds the old ones until the instance restarts.
before=$(pid)
px5g selfsigned -days 60 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout $KEY.new -out $CERT.new -subj /CN=127.0.0.1 >/dev/null 2>&1 &&
	mv $KEY.new $KEY && mv $CERT.new $CERT
"$INIT" reload
eventually "a reload after the certificate is renewed restarts the instance" restarted_from "$before"
eventually "which serves with it" logs_in
check "plain HTTP is not served" fails wget -q -O /dev/null "$URL"
check "check says basic auth is on, and for whom" says 'ok   main: HTTPS on interface loopback, port 9100, .*basic auth as user "prom"' "$INIT" check
check "status says it" says '^listening on https://127.0.0.1:9100/metrics, basic auth, gzip when asked, serving' "$INIT" status
check "so does the ubus object's status" auth_true
check "the hash is in no reply of the ubus object, nor in check, status or the log" no_hash_in secret_free

# Basic auth's file gone under a running instance, and uhttpd ended: procd
# starts it again as it was, and the jail has no file to mount. The handler
# reads that the config sets basic auth, and denies every request.
before=$(pid)
mv "$AUTH_FILE" "$AUTH_FILE.e2e"
kill -KILL "$(uhttpd_of)"
eventually "procd starts the instance again" restarted_from "$before"
denied() { [ "$(status_of "$@")" = 'HTTP error 500' ]; }
eventually "without basic auth's file, it denies a scrape with the right credentials" denied --user=prom --password=e2e-secret
check "and one without" denied
check "and logs why, at err" says "daemon.err $NAME\[[0-9]*\]: $AUTH_FILE is not there, and the config sets basic auth (auth_user): every request is denied" logread
mv "$AUTH_FILE.e2e" "$AUTH_FILE"
"$INIT" restart
eventually "a restart, which writes the file, logs in again" logs_in

# --- basic auth's cache, in the instance's state
# The file of the header let in last: <instance>.auth, which a request the
# cache lets in leaves as it was, and a full check replaces (a new inode).
cache_file() { ls "$STATE"/*.auth 2>/dev/null; }
inode() { ls -i "$(cache_file)" | awk '{ print $1 }'; }
no_cache() { [ -z "$(cache_file)" ]; }
state_private() { ls -ld "$STATE" | grep -q '^drwx------ ' && ls -l "$(cache_file)" | grep -q '^-rw------- '; }
digest_only() { grep -qx '[0-9a-f]\{64\}' "$(cache_file)" && ! grep -qF -e "$HASH" -e e2e-secret "$(cache_file)"; }
# The jail's mounts, read-write ones apart: procd shows each with its flag.
mounted_rw() { instance | jsonfilter -e "@[*].instances.instance1.mount['$1']" | grep -qx 1; }
check "the jail mounts the state directory read-write" mounted_rw "$STATE"
check "and the exporter's other mounts read-only" fails mounted_rw "$AUTH_FILE"
check "a scrape let in leaves the digest of its header there" test -n "$(cache_file)"
check "mode 0600, in a directory of mode 0700" state_private
check "a digest, neither the hash nor the password" digest_only
first=$(inode)
check "the same credentials scrape again" logs_in
check "by the cache: it keeps the entry as it was" test "$(inode)" = "$first"
check "a wrong password is still a 401" unauthorized --user=prom --password=wrong
check "and leaves the entry as it was" test "$(inode)" = "$first"
https --header="Authorization: basic $(ucode -e 'print(b64enc("prom:e2e-secret"))')" >/dev/null
check "the same credentials in another header pass the full check, which replaces the entry" fails test "$(inode)" = "$first"
before_cache=$(cache_file)
"$INIT" restart
eventually "after a restart it serves again" logs_in
check "a restarted instance starts without the state of the one before" test "$(cache_file)" != "$before_cache"
check "which it removed" test ! -e "$before_cache"
# What the cache saves a scrape: the mean milliseconds of one of loadavg alone,
# by the cache, and with its entry removed before each, by the full check, at
# the most rounds basic auth takes (SHA-512-crypt of 2000). Both run rm, the
# first on nothing. Shown, not checked: the difference, the hash's 8 ms here,
# is within what a busy machine varies by; the inode above is what shows the
# cache is used.
CAP=$(ucode -e "import { ROUNDS_MAX } from 'prometheus_exporter.auth'; print(ROUNDS_MAX);")
CAP_HASH=$(ucode -e "import { hash } from 'prometheus_exporter.crypt'; print(hash('e2e-secret', 'e2e-salt-e2e', $CAP));")
before=$(pid)
set_config "$NAME.main.auth_password=$CAP_HASH"
eventually "a new hash restarts the instance" restarted_from "$before"
eventually "a hash of $CAP rounds takes its password" logs_in
CREDENTIALS=$(ucode -e 'print(b64enc("prom:e2e-secret"))')
FETCH="uclient-fetch -q -O - --no-check-certificate --header='Authorization: Basic $CREDENTIALS' $HTTPS?collect[]=loadavg"
set -- $(scrape_ms "rm -f $STATE/none; $FETCH") $(scrape_ms "rm -f $STATE/*.auth; $FETCH")
echo "info a scrape of loadavg over HTTPS with basic auth ($CAP rounds), mean of $RUNS: $2 ms by the cache, $4 ms by the full check"
check "both were answered" test "$1" -gt 0 -a "$3" -gt 0
check "and the full check left the header's entry again" test -n "$(cache_file)"
cap_inode=$(inode)
check "validate refuses a hash of a round more, saying why" says "expected a hash of at most $CAP rounds" \
	rpc validate "{\"main\":{\"auth_user\":\"prom\",\"auth_password\":\"$(ucode -e "import { hash } from 'prometheus_exporter.crypt'; print(hash('x', 'e2e-salt-e2e', $CAP + 1));")\",\"cert\":\"$CERT\",\"key\":\"$KEY\"}}"
# A changed password invalidates the cache: the new hash restarts the instance,
# and the old password's entry lets nothing in, even were it kept.
NEW_HASH=$(rpc hash_password '{"password":"e2e-changed"}' | jsonfilter -e '@.hash')
set_config "$NAME.main.auth_password=$NEW_HASH"
changed_logs_in() { https --user=prom --password=e2e-changed | grep -q '^node_load1 '; }
eventually "a changed password takes the new one" changed_logs_in
check "and no longer the old one" unauthorized --user=prom --password=e2e-secret
check "the old password's entry is gone" fails test "$(inode)" = "$cap_inode"
# What uhttpd -m prints, an unsalted MD5-crypt hash, works too.
set_config "$NAME.main.auth_password=$(uhttpd -m e2e-md5)"
md5_logs_in() { https --user=prom --password=e2e-md5 | grep -q '^node_load1 '; }
eventually "a hash of uhttpd -m takes its password" md5_logs_in
check "and no other" unauthorized --user=prom --password=e2e-secret
# What basic auth costs a scrape: the mean milliseconds of one of loadavg alone,
# with the hash hash_password makes ($6$, 1000 rounds; each scrape after the
# first let in by the cache), then without basic auth.
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
