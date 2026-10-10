#!/bin/sh
# usage: same-code.sh REV [PATH...]
#
# Whether the sources of the working tree are REV's but for comments and blank
# lines: each ucode file of src/ and files/ that differs from REV's must compile
# to the same stripped bytecode (devenv/scripts/same-bytecode.sh, in the
# development image), and each JavaScript file of luci/ the same tokens, as
# esbuild minifies them without comments (in the browser tests' image). PATH
# narrows the files checked. make same-code REV=main runs it; it changes nothing.
set -eu
cd "$(dirname "$0")/../.."

: "${DEVENV_IMAGE:?run through make same-code}" "${BROWSER_IMAGE:?run through make same-code}"
rev=${1:?usage: same-code.sh REV [PATH...]}
shift
[ $# -gt 0 ] || set -- src files luci/htdocs

work=$(mktemp -d "${TMPDIR:-/tmp}/same-code.XXXXXX")
trap 'rm -rf "$work"' EXIT
chmod a+rx "$work"
git archive "$rev" src files luci | tar -x -C "$work"

ucode_files=
js_files=
for f in $(git diff --name-only "$rev" -- "$@"); do
	[ -f "$f" ] && [ -f "$work/$f" ] || continue
	case $f in
	*.uc|files/usr/bin/*) ucode_files="$ucode_files $f" ;;
	*.js) js_files="$js_files $f" ;;
	esac
done

status=0
if [ -n "$ucode_files" ]; then
	docker run --rm --network none -v "$PWD:/exporter:ro" -v "$work:/rev:ro" -w /exporter "$DEVENV_IMAGE" sh -c '
		status=0
		for f in "$@"; do
			devenv/scripts/same-bytecode.sh -L /exporter/src "/rev/$f" "$f" && echo "same code: $f" || status=1
		done
		exit $status' sh $ucode_files || status=1
fi

if [ -n "$js_files" ]; then
	docker run --rm --network none -v "$PWD:/exporter:ro" -v "$work:/rev:ro" "$BROWSER_IMAGE" node -e '
		const { transformSync } = require("esbuild");
		const fs = require("fs");
		const tokens = (p) => transformSync(`(function(){${fs.readFileSync(p, "utf8")}\n})`,
			{ minifyWhitespace: true, legalComments: "none", loader: "js" }).code;
		let status = 0;
		for (const f of process.argv.slice(1)) {
			if (tokens(`/rev/${f}`) === tokens(`/exporter/${f}`)) console.log(`same tokens: ${f}`);
			else { console.error(`same-code: ${f} has other tokens than at the revision`); status = 1; }
		}
		process.exit(status);' $js_files || status=1
fi

[ -n "$ucode_files$js_files" ] || echo "same-code: no ucode or JavaScript file differs from $rev"
exit $status
