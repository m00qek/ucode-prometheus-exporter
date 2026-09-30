#!/bin/sh
# What the package Makefile declares, for the checks that install the packages.
# usage: package-info.sh {feed-depends|base-collectors|groups}
#   feed-depends     every package the base package and the collector subpackages depend on
#   base-collectors  the collectors the base package installs
#   groups           one line per group package: its name, then its collectors' names
set -e
cd "$(dirname "$0")/../.."
mk=openwrt/prometheus-node-exporter-ucode/Makefile

case $1 in
feed-depends)
	{
		awk '/^define Package\/\$\(PKG_NAME\)$/ { p = 1 } p && /DEPENDS:=/ { sub(/.*DEPENDS:=/, ""); print; p = 0 }' "$mk"
		sed -n 's/^\$(eval \$(call Collector,[^,]*,[^,]*,[^,]*,\(.*\)))$/\1/p' "$mk"
	} | tr ' ' '\n' | sed 's/^+//' | grep -v -e '^$' -e '^prometheus-node-exporter-ucode$' | sort -u | tr '\n' ' '
	;;
base-collectors)
	sed -n 's/^BASE_COLLECTORS:=//p' "$mk"
	;;
groups)
	# X_GROUP:= lists, which may name other lists as $(Y_GROUP), then the
	# $(call Group,NAME,...,$(X_GROUP)) lines that use them.
	awk '
		function expand(v,    out, n, i, w, parts) {
			n = split(v, parts, /[ \t]+/)
			for (i = 1; i <= n; i++) {
				w = parts[i]
				if (w ~ /^\$\([A-Z_]+\)$/) w = expand(vars[substr(w, 3, length(w) - 3)])
				if (w != "") out = out (out == "" ? "" : " ") w
			}
			return out
		}
		/^[A-Z_]+_GROUP:=/ { i = index($0, ":="); vars[substr($0, 1, i - 1)] = substr($0, i + 2) }
		/^\$\(eval \$\(call Group,/ {
			line = $0; sub(/^\$\(eval \$\(call Group,/, "", line); sub(/\)\)$/, "", line)
			n = split(line, f, ",")
			print f[1] " " expand(f[n])
		}' "$mk"
	;;
*)
	echo "usage: $0 {feed-depends|base-collectors|groups}" >&2
	exit 2
	;;
esac
