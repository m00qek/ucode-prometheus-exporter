#!/bin/sh
# The benchmark on OpenWrt's malta target (mipsel_24kc, the package
# architecture of MT7621-class routers) under qemu-system-mipsel: one 24Kc
# CPU, QEMU_MEMORY of RAM, user-mode networking. Runs inside the qemu image
# (make bench-qemu), with the source tree at /exporter and bin/ at /artifacts.
#
# -icount shift=N,sleep=on runs the guest at one instruction every 2^N ns of
# its own clock, whatever the host's speed, so what the bench measures is the
# guest's instruction count, deterministic, at 1000/2^N MIPS: shift 0 is a
# 1000-MIPS CPU, 1 a 500-MIPS one, 2 a 250-MIPS one.
#
# The packages built in /artifacts are installed in the guest with their
# dependencies from the release's mipsel_24kc feed, and the bench runs on the
# installed exporter; its JSON comes back on the serial console.
#
# env: OPENWRT_VERSION, PKG_FULLVERSION, QEMU_SHIFT (1), QEMU_MEMORY (128),
#      BENCH_LABEL, BENCH_ARGS (bench.uc's), QEMU_TIMEOUT (seconds, 14400)
set -eu
version=$OPENWRT_VERSION
shift_n=${QEMU_SHIFT:-1}
memory=${QEMU_MEMORY:-128}
label=${BENCH_LABEL:-qemu-malta-shift$shift_n}
cache=/artifacts/qemu
work=$(mktemp -d)
base=https://downloads.openwrt.org/releases/$version/targets/malta/le
kernel=openwrt-$version-malta-le-vmlinux.elf
rootfs=openwrt-$version-malta-le-rootfs-ext4.img.gz

# ---- the release's images, verified against its sha256sums ----
mkdir -p "$cache/$version"
cd "$cache/$version"
[ -s sha256sums ] || wget -q "$base/sha256sums"
for f in $kernel $rootfs; do
	[ -s "$f" ] || wget -q "$base/$f"
	grep " \*\?$f\$" sha256sums | sed 's/ \*/  /' | sha256sum -c --status ||
		{ echo "$f does not match the release's sha256sums" >&2; rm -f "$f"; exit 1; }
done

# ---- the root filesystem, grown for the packages, with the boot script ----
gunzip -c "$rootfs" >"$work/root.img" || [ -s "$work/root.img" ] # gzip warns of the padding after the image
truncate -s 512M "$work/root.img"
e2fsck -fy "$work/root.img" >/dev/null 2>&1 || true
resize2fs "$work/root.img" >/dev/null 2>&1

cat >"$work/rc.local" <<'EOF'
#!/bin/sh
# Written by bench-qemu.sh: install the packages, run the bench, power off.
exec >/dev/console 2>&1
echo 'bench-qemu: booted'
mkdir -p /mnt/p && cd /mnt/p && tar -xf /dev/sdb
# QEMU's user-mode network: 10.0.2.15, its gateway 10.0.2.2 and DNS 10.0.2.3.
ip addr add 10.0.2.15/24 dev br-lan
ip route add default via 10.0.2.2
rm -f /etc/resolv.conf && echo 'nameserver 10.0.2.3' >/etc/resolv.conf
apk update >/dev/null && apk add --allow-untrusted $(cat packages) || echo 'bench-qemu: apk failed'
/etc/init.d/prometheus-exporter stop 2>/dev/null
echo 'bench-qemu: installed'
apk list -I 2>/dev/null | grep -E '^(ucode|ucode-prometheus-exporter|ucode-mod-[a-z0-9]+)-[0-9]' | sed 's/^/bench-qemu: /'
sh devenv/scripts/bench.sh run /mnt/p/worlds /tmp/out.json "$(cat label)" $(cat args) | sed 's/^/bench-qemu: /'
echo 'bench-qemu: BEGIN JSON'
cat /tmp/out.json
echo 'bench-qemu: END JSON'
poweroff
EOF
debugfs -w "$work/root.img" -f - >/dev/null 2>&1 <<EOF
rm /etc/rc.local
write $work/rc.local /etc/rc.local
sif /etc/rc.local mode 0100755
EOF

# ---- the payload, a tar on the second disk ----
mkdir -p "$work/payload"
cd /artifacts
echo "$label" >"$work/payload/label"
echo "${BENCH_ARGS:-}" >"$work/payload/args"
# The base package and the -full group, with its collectors: the bench's sets.
apks=ucode-prometheus-exporter-$PKG_FULLVERSION.apk
for p in full $(/exporter/devenv/scripts/package-info.sh groups | sed -n 's/^full //p'); do
	apks="$apks ucode-prometheus-exporter-$p-$PKG_FULLVERSION.apk"
done
ls $apks >/dev/null
echo $apks | tr ' ' '\n' | sed 's|^|/mnt/p/|' | tr '\n' ' ' >"$work/payload/packages"
tar -cf "$work/payload.tar" -C "$work/payload" label args packages -C /artifacts $apks -C /artifacts/bench worlds \
	-C /exporter test/bench test/lib/commands.uc devenv/scripts/bench.sh devenv/scripts/package-info.sh

# ---- boot, and wait for the guest to power off ----
echo "booting malta (24Kc, ${memory} MB, icount shift $shift_n); the bench runs in guest time, several times slower here" >&2
timeout "${QEMU_TIMEOUT:-14400}" qemu-system-mipsel -M malta -cpu 24Kc -smp 1 -m "$memory" \
	-kernel "$cache/$version/$kernel" -append 'root=/dev/sda rootwait console=ttyS0 loglevel=3' \
	-drive file="$work/root.img",format=raw,if=ide,index=0 \
	-drive file="$work/payload.tar",format=raw,if=ide,index=1 \
	-nic user,model=pcnet -icount shift="$shift_n",sleep=on -rtc clock=vm \
	-nographic -no-reboot -monitor none -serial stdio </dev/null >"$work/console" 2>&1 || true

grep '^bench-qemu: ' "$work/console" | grep -v -e 'BEGIN JSON' -e 'END JSON' | sed 's/^bench-qemu: //' >&2 || true
sed -n '/^bench-qemu: BEGIN JSON/,/^bench-qemu: END JSON/p' "$work/console" | sed '1d;$d' | tr -d '\r' >"$work/out.json"
if [ ! -s "$work/out.json" ]; then
	echo "no results; the console's end:" >&2
	tail -40 "$work/console" >&2
	exit 1
fi
mkdir -p /artifacts/bench
cp "$work/out.json" "/artifacts/bench/$label.json"
cp "$work/console" "/artifacts/bench/$label.console"
rm -rf "$work"
echo "results: bin/bench/$label.json" >&2
