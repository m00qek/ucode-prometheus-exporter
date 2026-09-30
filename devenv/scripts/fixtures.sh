#!/bin/sh
# usage: fixtures.sh HOST NAME
# Reads the sources in test/fixtures/SOURCES from HOST (an ssh destination) in one
# ssh session, into test/fixtures/NAME/. Only files not there yet are added, so
# the values tests assert on do not change under them; FORCE=1 replaces them all.
# Everything is read-only on the device: cat and ubus call.
set -e
cd "$(dirname "$0")/../.."

host=$1
name=$2
[ -n "$host" ] && [ -n "$name" ] || { echo "usage: $0 HOST NAME" >&2; exit 2; }

remote() {
	echo 'set -e; d=$(mktemp -d); cd "$d"'
	grep -v -e '^#' -e '^[[:space:]]*$' test/fixtures/SOURCES | while read -r kind a b args; do
		case $kind in
		file)
			echo "for f in $a; do [ -r \"\$f\" ] || continue; mkdir -p \".\$(dirname \"\$f\")\"; cat \"\$f\" >\".\$f\" 2>/dev/null || rm -f \".\$f\"; done"
			;;
		ubus)
			echo "mkdir -p ubus; ubus call '$a' '$b' ${args:+'$args'} >'ubus/$a.$b.json' 2>/dev/null || rm -f 'ubus/$a.$b.json'"
			;;
		*)
			echo "unknown source kind '$kind'" >&2
			exit 1
			;;
		esac
	done
	echo 'tar c . ; cd /; rm -rf "$d"'
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
remote | ssh "$host" sh -s | tar x -C "$tmp"

dest=test/fixtures/$name
mkdir -p "$dest"
(cd "$tmp" && find . -type f) | while read -r f; do
	if [ -e "$dest/$f" ] && [ "$FORCE" != 1 ]; then
		continue
	fi
	mkdir -p "$dest/$(dirname "$f")"
	cp "$tmp/$f" "$dest/$f"
	echo "$name/${f#./}"
done
