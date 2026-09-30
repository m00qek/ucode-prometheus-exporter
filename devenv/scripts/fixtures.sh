#!/bin/sh
# usage: fixtures.sh HOST NAME
# Reads the sources in test/fixtures/SOURCES from HOST (an ssh destination) in one
# ssh session, into test/fixtures/NAME/. Only files not there yet are added, so
# the values tests assert on do not change under them; FORCE=1 replaces them all.
# Everything is read-only on the device: cat, readlink, ubus call and ucode to
# reshape a reply. uci captures leave out secret options (keys, passwords) on
# the device; names, MAC and IP addresses are still to be redacted by hand.
set -e
cd "$(dirname "$0")/../.."

host=$1
name=$2
[ -n "$host" ] && [ -n "$name" ] || { echo "usage: $0 HOST NAME" >&2; exit 2; }

# Options of a uci section never copied off the device.
SECRETS='^(key[1-4]?|password|psk|secret|private_key|preshared_key|priv_key_pwd|auth_secret|acct_secret|sae_password)$'

sources() {
	grep -v -e '^#' -e '^[[:space:]]*$' test/fixtures/SOURCES
}

remote() {
	echo 'set -e; d=$(mktemp -d); cd "$d"'
	sources | grep -q '^link ' && echo "sep=''; printf '{' >links.json"
	sources | while read -r kind a b args; do
		case $kind in
		file)
			echo "for f in $a; do [ -r \"\$f\" ] || continue; mkdir -p \".\$(dirname \"\$f\")\"; cat \"\$f\" >\".\$f\" 2>/dev/null || rm -f \".\$f\"; done"
			;;
		ubus)
			echo "mkdir -p ubus; ubus call '$a' '$b' ${args:+'$args'} >'ubus/$a.$b.json' 2>/dev/null || rm -f 'ubus/$a.$b.json'"
			;;
		link)
			# Where each symlink the glob matches leads, into links.json: the fs mock has no symlinks.
			echo "for f in $a; do t=\$(readlink -f \"\$f\") || continue; printf '%s\n\t\"%s\": \"%s\"' \"\$sep\" \"\$f\" \"\$t\" >>links.json; sep=,; done"
			;;
		uci)
			# The config's sections as the uci mock's data, without secrets or uci's own bookkeeping.
			echo "mkdir -p uci; ubus call uci get '{\"config\":\"$a\"}' | ucode -e 'import * as fs from \"fs\"; let v = json(fs.stdin.read(\"all\")).values; for (let n, s in v) for (let k in keys(s)) if (match(k, /$SECRETS/) || k in [ \".anonymous\", \".index\", \".name\" ]) delete s[k]; printf(\"%.J\\n\", v);' >'uci/$a.json' 2>/dev/null || rm -f 'uci/$a.json'"
			;;
		*)
			echo "unknown source kind '$kind'" >&2
			exit 1
			;;
		esac
	done
	sources | grep -q '^link ' && echo "printf '\\n}\\n' >>links.json"
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
