#!/bin/sh
# make failure-demo's conntrack scenario, in the qemu image: one exporter on
# OpenWrt's malta target (little-endian, a 24Kc, 128 MB), booted, under
# procd, with its conntrack table full. The guest installs the exporter as a
# router would, ours from bin/ with its dependencies from the release's feed,
# the Lua one with FD_LUA's collectors from the feed; fills the table
# (conntrack.uc); starts the exporter's service on every address; says
# "ready", the line failure-demo.sh waits for; and FD_SCRAPES scrapes of 15 s
# later, scrapes it once itself (probe.uc), prints its log, and powers off.
#
# Without -icount, the guest's clock is the host's: Prometheus, outside,
# measures what the guest takes. How fast the guest is then depends on the
# host, and on the CPU share failure-demo.sh gives the container: the guest
# says how long a turn of a ucode loop takes it, as `make bench`'s
# calibrate:vm does (9.9 µs on bench-qemu's 500-MIPS 24Kc).
#
# Port 9100 of the container is the guest's. Lines of the console that
# start "guest: ", "probe: " or "log: ", and "ready", go to standard output.
#
# usage: qemu.sh {ours|lua}
# env: OPENWRT_VERSION, PKG_FULLVERSION, FD_LUA, FD_CONNTRACK, FD_SCRAPES
set -eu
exporter=$1
version=$OPENWRT_VERSION
cache=/artifacts/qemu/$version/le
work=$(mktemp -d)
base=https://downloads.openwrt.org/releases/$version/targets/malta/le
kernel=openwrt-$version-malta-le-vmlinux.elf
rootfs=openwrt-$version-malta-le-rootfs-ext4.img.gz

# ---- the release's images, verified against its sha256sums, as bench-qemu.sh ----
mkdir -p "$cache"
cd "$cache"
[ -s sha256sums ] || wget -q "$base/sha256sums"
for f in $kernel $rootfs; do
	[ -s "$f" ] || wget -q "$base/$f"
	grep " \*\?$f\$" sha256sums | sed 's/ \*/  /' | sha256sum -c --status ||
		{ echo "$f does not match the release's sha256sums" >&2; rm -f "$f"; exit 1; }
done
gunzip -c "$rootfs" >"$work/root.img" || [ -s "$work/root.img" ]
truncate -s 512M "$work/root.img"
e2fsck -fy "$work/root.img" >/dev/null 2>&1 || true
resize2fs "$work/root.img" >/dev/null 2>&1

# ---- the payload, a tar on the second disk ----
mkdir -p "$work/payload"
case $exporter in
ours)
	apks="ucode-prometheus-exporter-$PKG_FULLVERSION.apk"
	for p in full $(/exporter/devenv/scripts/package-info.sh groups | sed -n 's/^full //p'); do
		apks="$apks ucode-prometheus-exporter-$p-$PKG_FULLVERSION.apk"
	done
	echo $apks | tr ' ' '\n' | sed 's|^|/mnt/p/|' | tr '\n' ' ' >"$work/payload/packages"
	echo prometheus-exporter >"$work/payload/service"
	;;
lua)
	apks=
	echo prometheus-node-exporter-lua $FD_LUA | tr ' ' '\n' | sed '2,$s/^/prometheus-node-exporter-lua-/' | tr '\n' ' ' >"$work/payload/packages"
	echo prometheus-node-exporter-lua >"$work/payload/service"
	;;
*)
	echo "usage: $0 {ours|lua}" >&2
	exit 2
	;;
esac
echo "$FD_CONNTRACK" >"$work/payload/conntrack"
echo $((FD_SCRAPES * 15 + 30)) >"$work/payload/hold"
tar -cf "$work/payload.tar" -C "$work/payload" packages service conntrack hold -C /artifacts $apks \
	-C /exporter/devenv/scripts/failure-demo conntrack.uc probe.uc

cat >"$work/rc.local" <<'EOF'
#!/bin/sh
# Written by failure-demo/qemu.sh.
exec >/dev/console 2>&1
say() { echo "guest: $*"; }
mkdir -p /mnt/p && cd /mnt/p && tar -xf /dev/sdb
service=$(cat service)
say "booted, installing $service"

# QEMU's user-mode network on eth0 (br-lan): 10.0.2.15, its gateway 10.0.2.2
# and DNS 10.0.2.3. The WAN, eth1, is a link to nothing, 100.64.0.1, the
# firewall's wan zone, which masquerades; 198.18.0.0/15 is routed out of it.
ip addr add 10.0.2.15/24 dev br-lan
ip route add default via 10.0.2.2
rm -f /etc/resolv.conf && echo 'nameserver 10.0.2.3' >/etc/resolv.conf
uci set network.wan.proto=static
uci set network.wan.ipaddr=100.64.0.1
uci set network.wan.netmask=255.255.255.0
uci -q delete network.wan6 || true
uci commit network
/etc/init.d/network reload
i=0
until ip -4 addr show dev eth1 | grep -q 100.64.0.1 || [ $i -gt 30 ]; do i=$((i + 1)); sleep 1; done
ip neigh replace 100.64.0.2 lladdr 02:00:00:00:00:02 dev eth1 nud permanent
ip route add 198.18.0.0/15 via 100.64.0.2 dev eth1

apk update >/dev/null && apk add --allow-untrusted ucode-mod-socket $(cat packages) >/tmp/apk.log 2>&1 ||
	{ say "apk failed:"; sed 's/^/guest: /' /tmp/apk.log; }

# The table: an hour for each UDP connection, room for 64k.
sysctl -q -w net.netfilter.nf_conntrack_max=65536
sysctl -q -w net.netfilter.nf_conntrack_udp_timeout=3600
for h in $(seq 100 163); do ip addr add 192.168.1.$h/24 dev br-lan; done
ucode conntrack.uc "$(cat conntrack)" || say "conntrack.uc failed"
say "conntrack: $(cat /proc/sys/net/netfilter/nf_conntrack_count) connections"

uci set "$service.main.listen_interface=*"
uci commit "$service"
/etc/init.d/"$service" enable
/etc/init.d/"$service" restart
i=0
until netstat -ltn 2>/dev/null | grep -q ':9100 ' || [ $i -gt 60 ]; do i=$((i + 1)); sleep 1; done
say "$(ucode -e 'let t0 = clock(true); for (let i = 0; i < 1000000; i++); let t1 = clock(true);
	printf("a turn of a ucode loop takes %.1f us", ((t1[0] - t0[0]) + (t1[1] - t0[1]) / 1e9));')"
say "$(free | awk '/Mem:/ { printf("memory: %d kB free of %d", $4, $2) }')"
echo ready
sleep "$(cat hold)"
echo "probe: $(ucode probe.uc)"
logread | grep -v 'kernel:' | sed 's/^/log: /'
poweroff
EOF
debugfs -w "$work/root.img" -f - >/dev/null 2>&1 <<EOF
rm /etc/rc.local
write $work/rc.local /etc/rc.local
sif /etc/rc.local mode 0100755
EOF

# ---- boot: the WAN on a hub of its own, which nothing else is on ----
qemu-system-mipsel -M malta -cpu 24Kc -smp 1 -m 128 \
	-kernel "$cache/$kernel" -append 'root=/dev/sda rootwait console=ttyS0 loglevel=3' \
	-drive file="$work/root.img",format=raw,if=ide,index=0 \
	-drive file="$work/payload.tar",format=raw,if=ide,index=1 \
	-nic user,model=pcnet,hostfwd=tcp::9100-:9100 \
	-netdev hubport,id=wan,hubid=1 -device pcnet,netdev=wan \
	-rtc clock=host -nographic -no-reboot -monitor none -serial stdio </dev/null 2>&1 |
	awk '{ sub(/\r$/, "") } /^(ready$|guest: |probe: |log: )/ { print; fflush() }'
rm -rf "$work"
