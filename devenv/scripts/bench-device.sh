#!/bin/sh
# The benchmark on a device over ssh, beside whatever it runs: the sources,
# the bench and the worlds (generated here, in bin/bench/worlds) are copied to
# /tmp/prometheus-exporter-bench on the device, which is RAM, run there with
# the device's own ucode, and removed afterwards. Nothing is installed.
# usage: bench-device.sh HOST LABEL [bench.uc options...]
#   needs on the device: ucode, ucode-mod-fs, -ubus, -uci, -rtnl, -log
set -e
cd "$(dirname "$0")/../.."
host=$1 label=$2
shift 2
dir=/tmp/prometheus-exporter-bench

[ -f bin/bench/worlds/sets.json ] || {
	echo "no bin/bench/worlds: make bench-worlds" >&2
	exit 1
}

# shellcheck disable=SC2029 # $dir is expanded here on purpose
cleanup() { ssh "$host" "rm -rf '$dir'" || true; }
trap cleanup EXIT INT TERM

ssh "$host" "rm -rf '$dir' && mkdir -p '$dir'"
# BENCH_SRC: the directory whose src/ is benched (make's BENCH_REV), else this one's.
tar -czf - -C "${BENCH_SRC:-.}" src -C "$PWD" test/bench test/lib/commands.uc devenv/scripts/bench.sh -C "$PWD/bin/bench" worlds |
	ssh "$host" "tar -xzf - -C '$dir'"
mkdir -p bin/bench
# The bench's options, each single-quoted for the device's shell (a filter holds '|').
args=
for a in "$@"; do
	args="$args '$(printf %s "$a" | sed "s/'/'\\\\''/g")'"
done
ssh "$host" "cd '$dir' && sh devenv/scripts/bench.sh run '$dir/worlds' '$dir/out.json' '$label' $args"
ssh "$host" "cat '$dir/out.json'" >"bin/bench/$label.json"
echo "results: bin/bench/$label.json"
