#!/bin/sh
# make feed-inventory: docs/gen/feed-exporters.json, what the packages feed's
# Lua and ucode exporters write, from openwrt/packages at commit REF, which
# GitHub serves as a tarball (feed-inventory.uc reads it). make docs-gen
# writes the migration page from it; with --check, nothing is written, and it
# fails when the feed at REF is not what the file says.
# usage: feed-inventory.sh REF [--check]
set -eu
cd "$(dirname "$0")/../.."
ref=$1
out=docs/gen/feed-exporters.json
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

wget -q -O "$work/packages.tar.gz" "https://codeload.github.com/openwrt/packages/tar.gz/$ref"
mkdir "$work/src"
tar -xzf "$work/packages.tar.gz" -C "$work/src"
dir=$(ls -d "$work"/src/*)
ucode -L devenv/scripts devenv/scripts/feed-inventory.uc "$dir" "openwrt/packages@$ref" >"$work/inventory.json"

if [ "${2:-}" = --check ]; then
	cmp -s "$work/inventory.json" "$out" || { echo "$out is not what openwrt/packages@$ref has: run make feed-inventory" >&2; exit 1; }
	exit 0
fi
cp "$work/inventory.json" "$out"
echo "wrote $out"
