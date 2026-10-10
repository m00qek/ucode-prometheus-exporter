#!/bin/sh
# make lab: boots OpenWrt with procd as PID 1 in a privileged container (ujail
# needs it), installs the built packages and LuCI's, and leaves it running with
# LuCI and /metrics published on the host. make lab-down removes it.
# usage: lab.sh {up|down}
set -eu
cd "$(dirname "$0")/../.."

: "${LAB_NAME:?run through make lab}"

down() { docker rm -f "$LAB_NAME" >/dev/null 2>&1 || true; }

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

: "${LAB_IMAGE:?}" "${PKG_FULLVERSION:?}" "${LAB_ADDRESS:?}" "${LAB_LUCI_PORT:?}" "${LAB_METRICS_PORT:?}"

down
# Its own network namespace, on docker's default bridge: netifd, the jail and
# the services touch the container's network only.
docker run -d --privileged $(devenv/scripts/no-watchdog.sh) --name "$LAB_NAME" --hostname "$LAB_NAME" \
	-p "$LAB_ADDRESS:$LAB_LUCI_PORT:80" -p "$LAB_ADDRESS:$LAB_METRICS_PORT:9100" \
	-v "$PWD/bin:/artifacts:ro" -v "$PWD/devenv/services/lab:/opt/lab:ro" \
	--entrypoint /bin/sh "$LAB_IMAGE" /opt/lab/boot.sh >/dev/null

tries=0
until docker exec "$LAB_NAME" ubus -t 1 call network.interface.loopback status >/dev/null 2>&1; do
	tries=$((tries + 1))
	if [ "$tries" -gt 60 ] || [ "$(docker inspect -f '{{.State.Running}}' "$LAB_NAME" 2>/dev/null)" != true ]; then
		echo "OpenWrt did not boot:" >&2
		docker logs "$LAB_NAME" >&2 2>&1 || true
		exit 1
	fi
	sleep 1
done

docker exec -e PKG_FULLVERSION "$LAB_NAME" /opt/lab/setup.sh

[ "$LAB_NAME" = ucode-prometheus-exporter-lab ] && down_args= || down_args=" LAB_NAME=$LAB_NAME"
cat <<EOF
The lab runs, as container $LAB_NAME:
  LuCI      http://$LAB_ADDRESS:$LAB_LUCI_PORT/  (root, no password)
  /metrics  http://$LAB_ADDRESS:$LAB_METRICS_PORT/metrics
  a shell   docker exec -it $LAB_NAME ash
  stop it   make lab-down$down_args
EOF
