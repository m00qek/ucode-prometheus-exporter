#!/bin/sh
# make failure-demo: how this exporter and the feed's Lua exporter behave
# when something they read breaks, as a real Prometheus server sees them.
# Each scenario runs both exporters, each in a container of its own
# (devenv/scripts/failure-demo/run.sh), on a network of their own with a
# Prometheus server (the official image) that scrapes them every 15 s with
# its default 10 s timeout, FD_SCRAPES times. Then report.uc reads from its
# API what each scrape got, probe.uc scrapes each exporter once more from
# where it runs, without a scraper's timeout, and table.uc prints it all;
# the logs, the JSON and the tables stay in bin/failure-demo/.
#
# conntrack runs apart, on OpenWrt's malta target in QEMU
# (devenv/scripts/failure-demo/qemu.sh): each exporter on a booted router
# under procd, its conntrack table filled with FD_CONNTRACK connections.
#
# Nothing runs privileged; every container goes when the demo ends.
#
# usage: failure-demo.sh [SCENARIO...]
#   (healthy hung-ubus stuck-nft bad-utf8 conntrack; all by default)
# env: FD_IMAGE, FD_NAME, PROMETHEUS_IMAGE, PKG_FULLVERSION (from make);
#      FD_SCRAPES (8); QEMU_IMAGE, FD_QEMU_CPUS (0.65), FD_CONNTRACK (20000)
set -eu
cd "$(dirname "$0")/../.."

: "${FD_IMAGE:?run through make failure-demo}" "${FD_NAME:?}" "${PROMETHEUS_IMAGE:?}" "${PKG_FULLVERSION:?}"
SCRAPES=${FD_SCRAPES:-8}
INTERVAL=15
OUT=bin/failure-demo
NET=$FD_NAME
LABEL=ucode-prometheus-exporter.failure-demo=$FD_NAME
DEMO=/exporter/devenv/scripts/failure-demo

scenarios=${*:-healthy hung-ubus stuck-nft bad-utf8 conntrack}
in_docker=
for s in $scenarios; do
	case $s in
	healthy | hung-ubus | stuck-nft | bad-utf8) in_docker="$in_docker $s" ;;
	conntrack) ;;
	*) echo "no scenario $s: healthy, hung-ubus, stuck-nft, bad-utf8 or conntrack" >&2; exit 2 ;;
	esac
done

cleanup() {
	ids=$(docker ps -aq --filter "label=$LABEL")
	[ -z "$ids" ] || docker rm -f $ids >/dev/null 2>&1 || true
	docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$OUT" && chmod a+rwx bin "$OUT"
rm -f "$OUT"/*.json "$OUT"/*.log "$OUT"/*.md "$OUT"/prometheus*.yml
cleanup
docker network create --label "$LABEL" "$NET" >/dev/null

# Waits for container $1 to say "ready", for up to $2 seconds.
wait_ready() {
	i=0
	until docker logs "$1" 2>/dev/null | grep -qx ready; do
		i=$((i + 1))
		if [ "$i" -gt "$2" ] || [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" != true ]; then
			echo "$1 did not start:" >&2
			docker logs "$1" >&2 2>&1 || true
			exit 1
		fi
		sleep 1
	done
}

# A Prometheus server named $1 scraping each target of standard input,
# "<address> <scenario> <exporter>" a line, as the official image's defaults
# do but for the interval: 15 s, the usual, where its own default is 1 m.
prometheus() {
	{
		printf 'global:\n  scrape_interval: %ss\n  scrape_timeout: 10s\nscrape_configs:\n  - job_name: demo\n    static_configs:\n' "$INTERVAL"
		while read -r address scenario exporter; do
			printf '      - targets: ["%s"]\n        labels: { scenario: "%s", exporter: "%s" }\n' "$address" "$scenario" "$exporter"
		done
	} >"$OUT/$1.yml"
	chmod a+r "$OUT/$1.yml"
	docker run -d --label "$LABEL" --name "$FD_NAME-$1" --network "$NET" --network-alias "$1" \
		-v "$PWD/$OUT/$1.yml:/etc/prometheus/prometheus.yml:ro" "$PROMETHEUS_IMAGE" >/dev/null
}

# What Prometheus server $1 got, after FD_SCRAPES scrapes, into $2: report.uc,
# from a container on the network.
report() {
	sleep $((SCRAPES * INTERVAL + 5))
	docker run --rm --label "$LABEL" --network "$NET" -v "$PWD:/exporter:ro" "$FD_IMAGE" \
		ucode "$DEMO/report.uc" "http://$1:9090" $scenarios >"$2"
	# Paused, not removed: a scrape it has running ends as it would, rather
	# than with its connection.
	docker pause "$FD_NAME-$1" >/dev/null
}

if [ -n "$in_docker" ]; then
	echo "the containers' scenarios:$in_docker; $SCRAPES scrapes each, $((SCRAPES * INTERVAL / 60 + 2)) minutes or so" >&2
	for s in $in_docker; do
		for e in ours lua; do
			docker run -d --label "$LABEL" --name "$FD_NAME-$s-$e" --network "$NET" --network-alias "$s-$e" \
				--cap-add NET_ADMIN -e PKG_FULLVERSION \
				-v "$PWD/bin:/artifacts:ro" -v "$PWD:/exporter:ro" "$FD_IMAGE" "$DEMO/run.sh" "$e" "$s" >/dev/null
		done
	done
	for s in $in_docker; do
		for e in ours lua; do wait_ready "$FD_NAME-$s-$e" 180; done
	done

	for s in $in_docker; do
		for e in ours lua; do echo "$s-$e:9100 $s $e"; done
	done | prometheus prometheus
	report prometheus "$OUT/containers.json"

	# The probes at once: one that gets no reply waits for uhttpd's 60 s.
	for s in $in_docker; do
		for e in ours lua; do
			docker exec "$FD_NAME-$s-$e" ucode "$DEMO/probe.uc" >"$OUT/$s-$e.probe.json" &
		done
	done
	wait
	for s in $in_docker; do
		for e in ours lua; do
			docker exec "$FD_NAME-$s-$e" logread >"$OUT/$s-$e.log"
			docker rm -f "$FD_NAME-$s-$e" >/dev/null
		done
	done
fi

case " $scenarios " in
*" conntrack "*)
	: "${QEMU_IMAGE:?}"
	CONNTRACK=${FD_CONNTRACK:-20000}
	CPUS=${FD_QEMU_CPUS:-0.65}
	echo "conntrack: each exporter on QEMU's malta, ${CPUS} of a CPU, $CONNTRACK connections; 10 minutes or so each" >&2
	for e in lua ours; do
		docker run -d --label "$LABEL" --name "$FD_NAME-router" --network "$NET" --network-alias router \
			--cpu-period 20000 --cpu-quota "$(awk "BEGIN { print int($CPUS * 20000) }")" \
			-e OPENWRT_VERSION -e PKG_FULLVERSION -e FD_LUA -e FD_CONNTRACK="$CONNTRACK" -e FD_SCRAPES="$SCRAPES" \
			-v "$PWD:/exporter:ro" -v "$PWD/bin:/artifacts" "$QEMU_IMAGE" "$DEMO/qemu.sh" "$e" >/dev/null
		wait_ready "$FD_NAME-router" 1800
		echo "router:9100 conntrack $e" | prometheus "prometheus-$e"
		report "prometheus-$e" "$OUT/conntrack-$e.json"
		docker wait "$FD_NAME-router" >/dev/null
		docker logs "$FD_NAME-router" 2>&1 | sed -n 's/^probe: //p' >"$OUT/conntrack-$e.probe.json"
		docker logs "$FD_NAME-router" 2>&1 | sed -n 's/^log: //p' >"$OUT/conntrack-$e.log"
		docker logs "$FD_NAME-router" 2>&1 | grep '^guest: ' >&2 || true
		docker rm -f "$FD_NAME-router" >/dev/null
	done
	# One report for both: the two servers' targets.
	docker run --rm -v "$PWD:/exporter:ro" "$FD_IMAGE" ucode -e '
		import { readfile } from "fs";
		print(sprintf("%.2J\n", [ ...json(readfile(ARGV[0])), ...json(readfile(ARGV[1])) ]));' \
		/exporter/$OUT/conntrack-ours.json /exporter/$OUT/conntrack-lua.json >"$OUT/conntrack.json"
	;;
esac

reports=
[ -z "$in_docker" ] || reports="$reports /exporter/$OUT/containers.json"
case " $scenarios " in *" conntrack "*) reports="$reports /exporter/$OUT/conntrack.json" ;; esac
docker run --rm -v "$PWD:/exporter:ro" "$FD_IMAGE" ucode "$DEMO/table.uc" "/exporter/$OUT" $reports | tee "$OUT/results.md"
echo "logs, JSON and tables: $OUT/" >&2
