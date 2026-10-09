#!/bin/sh
# make failure-demo, in a container of the failure-demo image: installs one
# exporter, sets up the scenario, serves /metrics on port 9100, and stays up
# until the container is removed. "ready" on standard output once it serves.
#
# Both exporters run as their init scripts start them, uhttpd with the same
# options, without procd: no jail, as root, so that the container needs no
# privileges but CAP_NET_ADMIN, for nft. ubusd, logd and rpcd run; the
# stand-ins of ubus.uc answer for the services that do not. Either exporter
# has every collector package that installs here; the ubnt-manager package's
# sample radio, which is not there, is removed.
#
# Scenarios:
#   healthy      nothing wrong
#   hung-ubus    network.wireless, hostapd.wlan0 and dnsmasq never answer (hung.uc)
#   stuck-nft    nft never exits: the nft counters collectors run it
#   bad-utf8     a static DHCP lease's name is "caf\xe9", Latin-1, not UTF-8
#
# usage: run.sh {ours|lua} SCENARIO
# env: PKG_FULLVERSION (ours)
set -u
exporter=$1
scenario=$2
DEMO=/exporter/devenv/scripts/failure-demo
FIXTURES=/exporter/test/fixtures/caju-router

mkdir -p /var/run /var/lock /tmp/log
ubusd &
until [ -S /var/run/ubus/ubus.sock ]; do sleep 1; done
logd -S 256 &
ucode "$DEMO/ubus.uc" "$FIXTURES" "$([ "$scenario" = hung-ubus ] && echo hung)" &
[ "$scenario" = hung-ubus ] && ucode "$DEMO/hung.uc" &
ubus -t 10 wait_for system network.device

case $exporter in
ours)
	: "${PKG_FULLVERSION:?}"
	# The base package and the -full group, with its collectors, as the
	# benchmark installs them.
	set -- ucode-prometheus-exporter ucode-prometheus-exporter-full
	for c in $(/exporter/devenv/scripts/package-info.sh groups | sed -n 's/^full //p'); do
		set -- "$@" "ucode-prometheus-exporter-$c"
	done
	for p in "$@"; do echo "/artifacts/$p-$PKG_FULLVERSION.apk"; done |
		xargs apk add --allow-untrusted --no-network >/tmp/apk.log 2>&1 || { cat /tmp/apk.log; exit 1; }
	;;
lua)
	apk add --allow-untrusted --no-network /opt/lua/*.apk >/tmp/apk.log 2>&1 || { cat /tmp/apk.log; exit 1; }
	;;
*)
	echo "usage: $0 {ours|lua} SCENARIO" >&2
	exit 2
	;;
esac

# What a router has that a container does not: dnsmasq's lease file, and no
# ubnt-manager radio but those configured.
: >/tmp/dhcp.leases
uci -q delete ubnt-manager.sample_ap && uci commit ubnt-manager
rpcd &
ubus -t 10 wait_for rc file

case $scenario in
healthy | hung-ubus) ;;
stuck-nft)
	printf '#!/bin/sh\nexec sleep 86400\n' >/usr/sbin/nft
	;;
bad-utf8)
	uci -q add dhcp host >/dev/null
	uci set dhcp.@host[-1].name="$(printf 'caf\351')"
	uci set dhcp.@host[-1].mac=00:00:5e:00:53:01
	uci set dhcp.@host[-1].ip=192.168.1.10
	uci commit dhcp
	;;
*)
	echo "no scenario $scenario" >&2
	exit 2
	;;
esac

# Each init script's uhttpd, listening on every address: ours
# (files/etc/init.d/prometheus-exporter), and the Lua exporter's.
# uhttpd's stderr goes to the log, as procd sends it.
case $exporter in
ours)
	/usr/sbin/uhttpd -f -c /dev/null -h /dev/null -S -D -o /metrics -O /usr/libexec/prometheus-exporter/handler.uc \
		-k 70 -t 60 -n 3 -N 10 -p 9100 2>&1 | logger -t uhttpd &
	;;
lua)
	/usr/sbin/uhttpd -f -c /dev/null -l / -L /usr/bin/prometheus-node-exporter-lua -k 70 -p 9100 2>&1 |
		logger -t uhttpd &
	;;
esac

# Listening (port 9100 is 238C), without a scrape that would fill the ledger.
until cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk '$2 ~ /:238C$/ && $4 == "0A" { f = 1 } END { exit !f }'; do sleep 1; done
echo ready
wait
