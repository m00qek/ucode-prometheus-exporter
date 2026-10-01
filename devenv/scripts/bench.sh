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
	# The sets: the base package's collectors, and those with the -full group's.
	base=$(devenv/scripts/package-info.sh base-collectors)
	full=$(devenv/scripts/package-info.sh groups | sed -n 's/^full //p')
	ucode -e 'let b = split(trim(ARGV[0]), " "); printf("%J\n", { base: b, full: [ ...b, ...split(trim(ARGV[1]), " ") ] });' \
		"$base" "$full" >"$1/sets.json"
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
	exec ucode -L "$PWD/src" -L "$PWD/test" test/bench/bench.uc -w "$worlds" -o "$out" -l "$label" "$@"
	;;
*)
	echo "usage: $0 gen WORLDS | run WORLDS OUT.json LABEL [bench.uc options...]" >&2
	exit 2
	;;
esac
