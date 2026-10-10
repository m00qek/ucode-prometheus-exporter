#!/bin/sh
# usage: same-bytecode.sh [-L DIR]... A B
#
# Whether the ucode sources A and B compile to the same stripped bytecode
# (ucode -c -s), each function's source offset aside (devenv/scripts/
# bytecode.uc): the proof that they differ in comments and blank lines alone.
# A module (a file with a line that starts `export`) is compiled as what a
# program that imports it compiles to, the modules it imports with it, from
# the -L directories; a file that starts with a {% block, as a template
# (ucode -T). Exits 0 when they are the same, 1 when not, 2 when one does not
# compile; says which on standard error.
set -u

lib=
while [ $# -gt 2 ]; do
	case $1 in
	-L) lib="$lib -L $2"; shift 2 ;;
	*) break ;;
	esac
done
[ $# -eq 2 ] || { echo "usage: $0 [-L DIR]... A B" >&2; exit 2; }

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# $1: the source, $2: where its normalized bytecode goes.
compile() {
	src=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
	if grep -q '^export ' "$src"; then
		echo "import * as _ from '$src';" >"$work/importer.uc"
		ucode $lib -c -s -o "$work/bc" "$work/importer.uc" || return 2
	elif sed -n '/[^[:space:]]/{p;q;}' "$src" | grep -q '^[[:space:]]*{[%{]'; then
		ucode $lib -T -c -s -o "$work/bc" "$src" || return 2
	else
		ucode $lib -c -s -o "$work/bc" "$src" || return 2
	fi
	ucode "$here/bytecode.uc" "$work/bc" >"$2" || return 2
}

compile "$1" "$work/a" || { echo "same-bytecode: $1 does not compile" >&2; exit 2; }
compile "$2" "$work/b" || { echo "same-bytecode: $2 does not compile" >&2; exit 2; }
cmp -s "$work/a" "$work/b" || { echo "same-bytecode: $1 and $2 compile to different code" >&2; exit 1; }
