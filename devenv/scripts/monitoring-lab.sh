#!/bin/sh
# make monitoring-lab: a Prometheus that scrapes the lab (make lab) every 5
# seconds with the rules of monitoring/prometheus, a Grafana with the dashboards
# of monitoring/grafana, and a Perses with those of monitoring/perses, each its
# official image in a container of its own, unprivileged, on a network of their
# own; Prometheus joins docker's default bridge too, to reach the lab. Once
# they have a few minutes of the lab, monitoring-verify.py runs every panel's
# queries through Grafana and Perses, and screenshots each dashboard into
# bin/monitoring/. They are left running; make monitoring-lab-down removes them.
# usage: monitoring-lab.sh {up|down}
set -eu
cd "$(dirname "$0")/../.."

: "${LAB_NAME:?run through make monitoring-lab}"
net=$LAB_NAME-monitoring
out=bin/monitoring

down() {
	docker rm -f "$net-prometheus" "$net-grafana" "$net-perses" >/dev/null 2>&1 || true
	docker network rm "$net" >/dev/null 2>&1 || true
}

case ${1:-} in
down)
	down
	exit 0
	;;
up) ;;
*)
	echo "usage: $0 {up|down}" >&2
	exit 2
	;;
esac

: "${PROMETHEUS_IMAGE:?}" "${GRAFANA_IMAGE:?}" "${PERSES_IMAGE:?}" "${PYTHON_IMAGE:?}" "${BROWSER_IMAGE:?}" \
	"${MONITORING_ADDRESS:?}" "${PROMETHEUS_PORT:?}" "${GRAFANA_PORT:?}" "${PERSES_PORT:?}" "${MONITORING_WAIT:?}"

lab=$(docker inspect -f '{{.NetworkSettings.Networks.bridge.IPAddress}}' "$LAB_NAME" 2>/dev/null) || lab=
[ -n "$lab" ] || { echo "the lab $LAB_NAME does not run: make lab first" >&2; exit 1; }

down
rm -rf "$out"
mkdir -p "$out/screenshots"
chmod -R a+rwx "$out"

cat >"$out/prometheus.yml" <<EOF
global:
  scrape_interval: 5s
  evaluation_interval: 5s
rule_files:
  - /rules/*.rules.yml
scrape_configs:
  # Not the tutorial's job name: no rule or dashboard may depend on it.
  - job_name: node-remote
    static_configs:
      - targets: [ '$lab:9100' ]
EOF

docker network create "$net" >/dev/null

# extra-scrape-metrics: scrape_timeout_seconds, which the scrape duration
# panel and OpenWrtExporterScrapeSlow compare with.
docker run -d --name "$net-prometheus" --network "$net" --network-alias prometheus -u "$(id -u):$(id -g)" \
	-p "$MONITORING_ADDRESS:$PROMETHEUS_PORT:9090" \
	-v "$PWD/$out/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
	-v "$PWD/monitoring/prometheus:/rules:ro" \
	--tmpfs /prometheus:uid="$(id -u)" \
	"$PROMETHEUS_IMAGE" --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus \
	--enable-feature=extra-scrape-metrics >/dev/null
docker network connect bridge "$net-prometheus"

docker run -d --name "$net-grafana" --network "$net" --network-alias grafana \
	-p "$MONITORING_ADDRESS:$GRAFANA_PORT:3000" \
	-e GF_AUTH_ANONYMOUS_ENABLED=true -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin -e GF_AUTH_DISABLE_LOGIN_FORM=true \
	-e GF_ANALYTICS_REPORTING_ENABLED=false -e GF_ANALYTICS_CHECK_FOR_UPDATES=false -e GF_NEWS_NEWS_FEED_ENABLED=false \
	-v "$PWD/devenv/services/monitoring/grafana/provisioning.yaml:/etc/grafana/provisioning/datasources/lab.yaml:ro" \
	-v "$PWD/devenv/services/monitoring/grafana/provisioning.yaml:/etc/grafana/provisioning/dashboards/lab.yaml:ro" \
	-v "$PWD/monitoring/grafana:/var/lib/grafana/dashboards:ro" \
	"$GRAFANA_IMAGE" >/dev/null

docker run -d --name "$net-perses" --network "$net" --network-alias perses \
	-p "$MONITORING_ADDRESS:$PERSES_PORT:8080" \
	-v "$PWD/devenv/services/monitoring/perses:/etc/perses/lab:ro" \
	-v "$PWD/devenv/services/monitoring/perses/provisioning:/etc/perses/provisioning:ro" \
	--tmpfs /perses:uid=65532 \
	"$PERSES_IMAGE" --config=/etc/perses/lab/config.yaml --log.level=error >/dev/null

wait_for() {
	tries=0
	until curl -fs -o /dev/null "$2"; do
		tries=$((tries + 1))
		[ "$tries" -le 60 ] || { echo "$1 did not come up:" >&2; docker logs "$net-$1" 2>&1 | tail -20 >&2; exit 1; }
		sleep 1
	done
}
wait_for prometheus "http://$MONITORING_ADDRESS:$PROMETHEUS_PORT/-/ready"
wait_for grafana "http://$MONITORING_ADDRESS:$GRAFANA_PORT/api/health"
wait_for perses "http://$MONITORING_ADDRESS:$PERSES_PORT/api/v1/projects/openwrt"

# The dashboards into the project, as a user applies them, after percli's
# online lint: the server's plugins check each panel.
percli() {
	docker run --rm --network "$net" -u "$(id -u):$(id -g)" -v "$PWD/monitoring/perses:/dashboards:ro" \
		-v "$PWD/$out:/work" --entrypoint /bin/percli "$PERSES_IMAGE" --percliconfig /work/percli.json "$@"
}
percli login http://perses:8080 >/dev/null
for f in monitoring/perses/*.yaml; do
	percli lint --online -f "/dashboards/$(basename "$f")"
	percli apply --project openwrt -f "/dashboards/$(basename "$f")"
done

echo "waiting $MONITORING_WAIT s for scrapes of the lab"
sleep "$MONITORING_WAIT"

status=0
docker run --rm --network host -u "$(id -u):$(id -g)" -v "$PWD:/exporter:ro" -v "$PWD/$out:/out" -w /exporter \
	-e GRAFANA_URL="http://$MONITORING_ADDRESS:$GRAFANA_PORT" -e PERSES_URL="http://$MONITORING_ADDRESS:$PERSES_PORT" \
	-e PROMETHEUS_URL="http://$MONITORING_ADDRESS:$PROMETHEUS_PORT" -e REPORT=/out/report.txt \
	--entrypoint python3 "$PYTHON_IMAGE" -I devenv/scripts/monitoring-verify.py || status=1

docker run --rm --network host -u "$(id -u):$(id -g)" -e HOME=/tmp \
	-e GRAFANA_URL="http://$MONITORING_ADDRESS:$GRAFANA_PORT" -e PERSES_URL="http://$MONITORING_ADDRESS:$PERSES_PORT" \
	-v "$PWD/devenv/services/monitoring/screenshots.mjs:/app/screenshots.mjs:ro" \
	-v "$PWD/$out/screenshots:/out" \
	"$BROWSER_IMAGE" node /app/screenshots.mjs /out || status=1

[ "$LAB_NAME" = ucode-prometheus-exporter-lab ] && down_args= || down_args=" LAB_NAME=$LAB_NAME"
cat <<EOF
Monitoring the lab $LAB_NAME:
  Prometheus  http://$MONITORING_ADDRESS:$PROMETHEUS_PORT/alerts
  Grafana     http://$MONITORING_ADDRESS:$GRAFANA_PORT/dashboards  (no login)
  Perses      http://$MONITORING_ADDRESS:$PERSES_PORT/projects/openwrt
  results     $out/report.txt, $out/screenshots/
  stop it     make monitoring-lab-down$down_args
EOF
exit $status
