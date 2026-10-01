#!/bin/sh
# Runs in the booted lab container (make lab), with the built packages in
# /artifacts. Installs them as a device would: the exporter, every collector
# package, the groups and the LuCI app, which start and enable themselves. Then
# serves /metrics on every address, which docker's published port needs (the
# default is loopback alone). root's password is empty, as on a new device:
# LuCI's login takes it.
set -eu

: "${PKG_FULLVERSION:?run through make lab}"
PKG=ucode-prometheus-exporter
NAME=prometheus-exporter

passwd -d root >/dev/null 2>&1

apk add --allow-untrusted --no-network "/artifacts/$PKG-$PKG_FULLVERSION.apk" /artifacts/$PKG-*-"$PKG_FULLVERSION.apk" \
	"/artifacts/luci-app-$NAME-$PKG_FULLVERSION.apk" >/tmp/lab-install.log 2>&1 ||
	{ cat /tmp/lab-install.log >&2; exit 1; }

# Something for textfile to read, in the directory the service made.
echo 'lab_textfile_example{source="make lab"} 1' >/var/prometheus/lab.prom

uci set "$NAME.main.listen_interface=*"
uci commit "$NAME"
/etc/init.d/"$NAME" reload

tries=0
until wget -q -T 10 -O /dev/null http://127.0.0.1:9100/metrics 2>/dev/null; do
	tries=$((tries + 1))
	[ "$tries" -le 30 ] || { echo "the exporter did not come up:" >&2; logread | tail -20 >&2; exit 1; }
	sleep 1
done
