#!/bin/sh
# Runs as the LuCI container's command, with no network but loopback. Installs the
# built exporter, the collector packages in $BROWSER_COLLECTORS and the LuCI app
# offline, adds the test collectors of /fixtures/collectors, then starts ubusd, rpcd,
# uhttpd and the fake procd by hand (nothing here boots procd), and stays in the
# foreground while they run.
set -eu

: "${PKG_FULLVERSION:?run through make browser}" "${BROWSER_COLLECTORS:?}"

PKG=ucode-prometheus-exporter
NAME=prometheus-exporter
COLLECTORS=/usr/share/ucode/prometheus_exporter/collectors

# The package scripts reload services through procd, which is not running.
set -- "/artifacts/$PKG-$PKG_FULLVERSION.apk" "/artifacts/luci-app-$NAME-$PKG_FULLVERSION.apk"
for c in $BROWSER_COLLECTORS; do
	set -- "$@" "/artifacts/$PKG-$c-$PKG_FULLVERSION.apk"
done
apk add --allow-untrusted --no-network "$@" >/tmp/install.log 2>&1 || { cat /tmp/install.log >&2; exit 1; }

# Collectors no package has: one with an option of each type, one whose help and
# error are markup.
cp /fixtures/collectors/*.uc "$COLLECTORS/"

touch /etc/config/network /etc/config/system
uci batch </fixtures/router.uci
printf 'admin\nadmin\n' | passwd root >/dev/null 2>&1
cp /opt/luci/acl.json /usr/share/rpcd/acl.d/exporter-browser-tests.json

# A login granted luci-base and the app's ACL alone, as an administrator would grant
# it: the tests prove the app works with that and reads nothing of network. Every
# login also needs rpcd's own `unauthenticated` group, for `session access`.
echo 'metrics:x:1000:1000:metrics:/var:/bin/false' >>/etc/passwd
echo 'metrics:*:0:0:99999:7:::' >>/etc/shadow
printf 'metrics\nmetrics\n' | passwd metrics >/dev/null 2>&1
uci batch <<-'EOF'
	add rpcd login
	set rpcd.@login[-1].username='metrics'
	set rpcd.@login[-1].password='$p$metrics'
	add_list rpcd.@login[-1].read='unauthenticated'
	add_list rpcd.@login[-1].read='luci-base'
	add_list rpcd.@login[-1].read='luci-app-prometheus-exporter'
	add_list rpcd.@login[-1].write='luci-base'
	add_list rpcd.@login[-1].write='luci-app-prometheus-exporter'
	commit rpcd
EOF

# A login granted the same for reading alone: LuCI shows it the pages read-only.
echo 'viewer:x:1001:1001:viewer:/var:/bin/false' >>/etc/passwd
echo 'viewer:*:0:0:99999:7:::' >>/etc/shadow
printf 'viewer\nviewer\n' | passwd viewer >/dev/null 2>&1
uci batch <<-'EOF'
	add rpcd login
	set rpcd.@login[-1].username='viewer'
	set rpcd.@login[-1].password='$p$viewer'
	add_list rpcd.@login[-1].read='unauthenticated'
	add_list rpcd.@login[-1].read='luci-base'
	add_list rpcd.@login[-1].read='luci-app-prometheus-exporter'
	commit rpcd
EOF

mkdir -p /var/run/ubus /var/lock
ubusd &
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S /var/run/ubus/ubus.sock ] && break; sleep 1; done
rpcd &
ubus -t 10 wait_for session uci "$NAME"

FIXTURES=/fixtures ucode /opt/luci/fake-procd.uc &
ubus -t 10 wait_for system service exporter.fixture

# The flags /etc/init.d/uhttpd derives from the shipped config, on loopback only.
uhttpd -f -h /www -r OpenWrt -x /cgi-bin -u /ubus -t 60 -T 30 -k 20 -A 1 -n 3 -N 100 -p 127.0.0.1:80 &

echo "luci ready"
wait
