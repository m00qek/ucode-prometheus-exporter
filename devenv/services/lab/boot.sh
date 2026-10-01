#!/bin/sh
# The lab container's command (make lab): sets OpenWrt up for a container, then
# boots it, with procd as PID 1.
#
# Docker gives eth0 its address and route, and forwards the published ports to
# it. OpenWrt's first boot would generate a network config with a lan bridge
# over eth0 and an address of its own, and netifd takes down a device it is
# not told about; fw4 would reject what arrives on eth0, in no zone; and mwan3
# would rewrite the routing. So lan is eth0 itself, no bridge, with the address
# and gateway docker gave it, and the firewall and mwan3 (a collector's
# dependency) do not start.
set -eu

address=$(ip -4 -o addr show dev eth0 | awk '{ print $4; exit }')
gateway=$(ip -4 route show default | awk '{ print $3; exit }')

cat >/etc/config/network <<EOF
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config interface 'lan'
	option device 'eth0'
	option proto 'static'
	option ipaddr '$address'
	option gateway '$gateway'
EOF

for service in firewall mwan3; do
	[ ! -x "/etc/init.d/$service" ] || /etc/init.d/"$service" disable
done

# unbound on a port of its own (dnsmasq has 53), with its control socket where
# its collector looks by default, in the directory its package makes.
if [ -x /etc/init.d/unbound ]; then
	uci set unbound.ub_main.listen_port=5353
	uci commit unbound
	printf 'remote-control:\n\tcontrol-enable: yes\n\tcontrol-interface: /var/lib/unbound/unbound.ctl\n' \
		>/etc/unbound/unbound_ext.conf
fi

# ubnt-manager ships a sample radio, 192.168.1.20, which it reaches over ssh:
# with a route out, each scrape would wait for ssh to give up on it.
uci -q delete ubnt-manager.sample_ap && uci commit ubnt-manager

exec /sbin/init
