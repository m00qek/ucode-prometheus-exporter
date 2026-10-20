#!/bin/sh
# The benchmark (test/bench/), on OpenWrt: in a container (make bench), in
# QEMU (make bench-qemu) or on a device (make bench-device).
# usage: bench.sh gen WORLDS            write the worlds and the collector sets
#        bench.sh run WORLDS OUT.json LABEL [bench.uc options...]
#                                       run every case, generating the worlds unless they are there
set -e
cd "$(dirname "$0")/../.."

gen() {
	mkdir -p "$1"
	ucode -L "$PWD/src" -L "$PWD/test" test/bench/gen.uc "$1"
	# The sets: the base package's collectors, and those with the -full group's;
	# and, alone, collectors in no group that the worlds have a service for.
	base=$(devenv/scripts/package-info.sh base-collectors)
	full=$(devenv/scripts/package-info.sh groups | sed -n 's/^full //p')
	extra='chrony agh'
	ucode -e 'let b = split(trim(ARGV[0]), " "); printf("%J\n", { base: b, full: [ ...b, ...split(trim(ARGV[1]), " ") ], extra: split(trim(ARGV[2]), " ") });' \
		"$base" "$full" "$extra" >"$1/sets.json"
}

case $1 in
gen)
	gen "$2"
	;;
run)
	worlds=$2 out=$3 label=$4
	shift 4
	[ -f "$worlds/sets.json" ] || gen "$worlds"
	mkdir -p "$(dirname "$out")"
	# uhttpd's ucode finds the exporter in /usr/share/ucode alone: in make
	# bench's container, which has none installed, the handler: cases find
	# this tree's there. Never on a device or in QEMU, which have their own.
	if [ -n "${BENCH_LINK_EXPORTER:-}" ] && [ ! -e /usr/share/ucode/prometheus ]; then
		ln -s "$PWD/src/prometheus" /usr/share/ucode/prometheus
	fi
	exec ucode -L "$PWD/src" -L "$PWD/test" test/bench/bench.uc -w "$worlds" -o "$out" -l "$label" "$@"
	;;
*)
	echo "usage: $0 gen WORLDS | run WORLDS OUT.json LABEL [bench.uc options...]" >&2
	exit 2
	;;
esac
