#!/bin/sh
# Runs inside the openwrt container, from make test.
# Every ucode and JavaScript file the packages install, stripped of its
# comments as the package build strips it (devenv/scripts/strip-comments.py):
# a ucode file must compile to the same stripped bytecode as its source
# (devenv/scripts/same-bytecode.sh), with as many lines; a LuCI view must
# still parse as LuCI compiles it. make browser compares the views' tokens.
cd "$(dirname "$0")/../.."
status=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() { echo "strip-check: $*" >&2; status=1; }

for f in $(find src files/usr/libexec files/usr/share/rpcd -name '*.uc') files/usr/bin/prometheus-exporter; do
	out=$work/$f
	mkdir -p "$(dirname "$out")"
	python3 devenv/scripts/strip-comments.py "$f" >"$out" || { fail "$f does not strip"; continue; }
	[ "$(wc -l <"$f")" = "$(wc -l <"$out")" ] || fail "$f: the lines changed"
	devenv/scripts/same-bytecode.sh -L "$PWD/src" "$f" "$out" || status=1
done

for f in $(find luci/htdocs -name '*.js'); do
	out=$work/$f
	mkdir -p "$(dirname "$out")"
	python3 devenv/scripts/strip-comments.py "$f" >"$out" || { fail "$f does not strip"; continue; }
	[ "$(wc -l <"$f")" = "$(wc -l <"$out")" ] || fail "$f: the lines changed"
	qjs --std -e 'new Function(std.loadFile(scriptArgs[0]))' "$out" || fail "$f does not parse stripped"
done

# The stripper's own cases.
python3 test/strip/strip_comments_test.py >"$work/unittest.log" 2>&1 ||
	{ cat "$work/unittest.log" >&2; fail 'test/strip/strip_comments_test.py failed'; }

exit $status
