#!/bin/sh
# The benchmark (test/bench/), on OpenWrt: in a container (make bench), in
# QEMU (make bench-qemu) or on a device (make bench-device). Generates the
# worlds unless they are there, then runs every case.
# usage: bench.sh OUT.json LABEL [bench.uc options...]
#   BENCH_WORLDS  where the worlds are, or go (/tmp/bench-worlds)
set -e
cd "$(dirname "$0")/../.."
out=$1 label=$2
shift 2

worlds=${BENCH_WORLDS:-/tmp/bench-worlds}
if [ ! -f "$worlds/sets.json" ]; then
	mkdir -p "$worlds"
	ucode -L "$PWD/src" -L "$PWD/test" test/bench/gen.uc "$worlds"
	# The sets: the base package's collectors, and those with the -full group's.
	base=$(devenv/scripts/package-info.sh base-collectors)
	full=$(devenv/scripts/package-info.sh groups | sed -n 's/^full //p')
	ucode -e 'let b = split(trim(ARGV[0]), " "); printf("%J\n", { base: b, full: [ ...b, ...split(trim(ARGV[1]), " ") ] });' \
		"$base" "$full" >"$worlds/sets.json"
fi

mkdir -p "$(dirname "$out")"
exec ucode -L "$PWD/src" -L "$PWD/test" test/bench/bench.uc -w "$worlds" -o "$out" -l "$label" "$@"
