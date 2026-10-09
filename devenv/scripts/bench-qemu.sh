#!/bin/sh
# The benchmark on OpenWrt's malta target under QEMU: one 24Kc CPU,
# QEMU_MEMORY of RAM, user-mode networking. QEMU_ENDIAN is the byte order:
# le, the default, is malta/le under qemu-system-mipsel, the mipsel_24kc
# packages of MT7621-class routers; be is malta/be under qemu-system-mips,
# the mips_24kc packages of ath79-class ones, the most common small routers.
# Runs inside the qemu image (make bench-qemu), with the source tree at
# /exporter and bin/ at /artifacts.
#
# -icount shift=N,sleep=on runs the guest at one instruction every 2^N ns of
# its own clock, whatever the host's speed, so what the bench measures is the
# guest's instruction count, deterministic, at 1000/2^N MIPS: shift 0 is a
# 1000-MIPS CPU, 1 a 500-MIPS one, 2 a 250-MIPS one.
#
# The packages built in /artifacts are installed in the guest with their
# dependencies from the release's feed of the target's architecture. The
# guest then checks, on the installed exporter, what reads data in the CPU's
# own byte order (qemu-checks.uc), and runs the bench on it. Before, while
# the service runs as installed, it says what the packages take of the flash
# (each new package's installed size), what the service's uhttpd holds and
# what the guest has left (free), and whether it serves every collector:
# the `service:` and `size:` lines. All come back on the serial console, the
# bench's JSON too; a check that fails, or does not run, fails the run once
# the results are saved.
#
# env: OPENWRT_VERSION, PKG_FULLVERSION, QEMU_ENDIAN (le), QEMU_SHIFT (1),
#      QEMU_MEMORY (128), BENCH_LABEL, BENCH_ARGS (bench.uc's),
#      QEMU_TIMEOUT (seconds, 14400)
set -eu
version=$OPENWRT_VERSION
endian=${QEMU_ENDIAN:-le}
shift_n=${QEMU_SHIFT:-1}
memory=${QEMU_MEMORY:-128}
case $endian in
le) qemu=qemu-system-mipsel arch=mipsel_24kc ;;
be) qemu=qemu-system-mips arch=mips_24kc ;;
*) echo "QEMU_ENDIAN is le or be, not $endian" >&2; exit 2 ;;
esac
label=${BENCH_LABEL:-qemu-malta$([ "$endian" = le ] || echo "-$endian")-shift$shift_n}
cache=/artifacts/qemu/$version/$endian
work=$(mktemp -d)
base=https://downloads.openwrt.org/releases/$version/targets/malta/$endian
kernel=openwrt-$version-malta-$endian-vmlinux.elf
rootfs=openwrt-$version-malta-$endian-rootfs-ext4.img.gz

# ---- the release's images, verified against its sha256sums ----
# Each byte order has its own sha256sums, so its own directory.
mkdir -p "$cache"
cd "$cache"
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
apk info 2>/dev/null | sort >/tmp/before
apk update >/dev/null && apk add --allow-untrusted $(cat packages) || echo 'bench-qemu: apk failed'
echo 'bench-qemu: installed'
# What the install added, each package's installed size: the exporter's and
# the dependencies the release's image lacked.
for p in $(apk info 2>/dev/null | sort | grep -vxF -f /tmp/before); do
	echo "bench-qemu: size: $p $(apk info -s "$p" 2>/dev/null | sed -n 2p)"
done
# The service as installed, once a scrape succeeds: what its uhttpd holds,
# what the guest has left, and how many collectors it serves.
i=0
until wget -q -O /tmp/metrics http://127.0.0.1:9100/metrics 2>/dev/null || [ $i -ge 90 ]; do sleep 2; i=$((i + 1)); done
wget -q -O /tmp/metrics http://127.0.0.1:9100/metrics 2>/dev/null
echo "bench-qemu: service: serves $(grep -c '^node_scrape_collector_success{.*} 1$' /tmp/metrics) of $(grep -c '^node_scrape_collector_success{' /tmp/metrics) collectors, $(grep -c '^[a-z]' /tmp/metrics) samples"
for p in $(pidof uhttpd); do
	grep -q prometheus-exporter "/proc/$p/cmdline" &&
		echo "bench-qemu: service: uhttpd $(grep -E '^(VmRSS|RssAnon|VmData)' "/proc/$p/status" | tr -s ' \t' ' ' | tr '\n' ' ')"
done
free | sed 's/^/bench-qemu: service: /'
/etc/init.d/prometheus-exporter stop 2>/dev/null
apk list -I 2>/dev/null | grep -E '^(ucode|ucode-prometheus-exporter|ucode-mod-[a-z0-9]+)-[0-9]' | sed 's/^/bench-qemu: /'
ucode devenv/scripts/qemu-checks.uc 2>&1 | sed 's/^/bench-qemu: check: /'
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
# The base package and the -full group, with its collectors: the bench's sets;
# and the command line's package, which the checks scrape with, with
# ucode-docopt, from its author's feed, which make bench-qemu fetched.
apks="ucode-prometheus-exporter-$PKG_FULLVERSION.apk ucode-prometheus-exporter-cli-$PKG_FULLVERSION.apk $(cd /artifacts && ls ucode-docopt-*.apk)"
for p in full $(/exporter/devenv/scripts/package-info.sh groups | sed -n 's/^full //p'); do
	apks="$apks ucode-prometheus-exporter-$p-$PKG_FULLVERSION.apk"
done
ls $apks >/dev/null
echo $apks | tr ' ' '\n' | sed 's|^|/mnt/p/|' | tr '\n' ' ' >"$work/payload/packages"
tar -cf "$work/payload.tar" -C "$work/payload" label args packages -C /artifacts $apks -C /artifacts/bench worlds \
	-C /exporter test/bench test/lib/commands.uc devenv/scripts/bench.sh devenv/scripts/package-info.sh \
	devenv/scripts/qemu-checks.uc

# ---- boot, and wait for the guest to power off ----
echo "booting malta/$endian ($arch, 24Kc, ${memory} MB, icount shift $shift_n); the bench runs in guest time, several times slower here" >&2
timeout "${QEMU_TIMEOUT:-14400}" "$qemu" -M malta -cpu 24Kc -smp 1 -m "$memory" \
	-kernel "$cache/$kernel" -append 'root=/dev/sda rootwait console=ttyS0 loglevel=3' \
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
echo "results: bin/bench/$label.json" >&2
if ! grep -q '^bench-qemu: check: ok ' "$work/console" || grep -q '^bench-qemu: check: FAILED ' "$work/console"; then
	echo "the guest's checks failed, or did not run: see above" >&2
	rm -rf "$work"
	exit 1
fi
rm -rf "$work"
