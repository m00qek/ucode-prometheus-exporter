#!/bin/sh
# make luci-screenshots: the LuCI app's screenshots in the docs, from a lab of
# their own (make lab, run by the target, under LAB_NAME). Playwright joins the
# lab's network namespace, unprivileged, logs in as the lab's root, whose
# password is empty, and writes docs/how-to/img/luci-*.png, which pngquant then
# shrinks. The target removes the lab afterwards, whatever happens here.
set -eu
cd "$(dirname "$0")/../.."

: "${LAB_NAME:?run through make luci-screenshots}" "${BROWSER_IMAGE:?}"

out=docs/how-to/img
work=bin/luci-screenshots

rm -rf "$work"
mkdir -p "$work"
chmod a+rwx "$work"

# The status page's test run needs the collectors' first scrape done.
tries=0
until docker exec "$LAB_NAME" wget -q -T 10 -O /dev/null http://127.0.0.1:9100/metrics 2>/dev/null; do
	tries=$((tries + 1))
	[ "$tries" -le 30 ] || { echo "the lab's exporter does not answer" >&2; exit 1; }
	sleep 1
done

docker run --rm --network "container:$LAB_NAME" -u "$(id -u):$(id -g)" -e HOME=/tmp \
	-v "$PWD/devenv/services/browser/luci-screenshots.mjs:/app/luci-screenshots.mjs:ro" \
	-v "$PWD/$work:/out" \
	"$BROWSER_IMAGE" node /app/luci-screenshots.mjs /out

docker run --rm --network none -u "$(id -u):$(id -g)" -v "$PWD/$work:/out" \
	"$BROWSER_IMAGE" pngquant --force --skip-if-larger --strip --ext .png --quality 70-95 -- /out/luci-general.png \
	/out/luci-collectors.png /out/luci-edit.png /out/luci-change-password.png /out/luci-status.png || true

cp "$work"/luci-*.png "$out/"
ls -l "$out"/luci-*.png
