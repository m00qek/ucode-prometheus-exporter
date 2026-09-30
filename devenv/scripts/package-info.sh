#!/bin/sh
# What the package Makefile declares, for the checks that install the packages.
# usage: package-info.sh {feed-depends|base-collectors}
#   feed-depends     every package the base package and the collector subpackages depend on
#   base-collectors  the collectors the base package installs
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
*)
	echo "usage: $0 {feed-depends|base-collectors}" >&2
	exit 2
	;;
esac
