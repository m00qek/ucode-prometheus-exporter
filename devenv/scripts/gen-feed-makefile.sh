#!/bin/sh
# Generates the ucode-prometheus-exporter Makefile for the packages.ucode.dev
# feed.
#
# The feed builds the exporter, its collector packages, its groups and
# luci-app-prometheus-exporter from the release tarball GitHub serves for a
# tag, not from this tree. Its Makefile is openwrt/ucode-prometheus-exporter/
# Makefile with a fixed set of changes:
#
#   1. after PKG_RELEASE, the source lines: PKG_SOURCE, named after the package
#      so that it cannot clash in dl/ with another project's v<version>.tar.gz,
#      PKG_SOURCE_URL and PKG_SOURCE_URL_FILE, where GitHub serves it,
#      PKG_HASH (the tarball's sha256) and PKG_BUILD_DIR;
#   2. every ./src/, ./files/, ./luci/ and ./devenv/ path points into
#      $(PKG_BUILD_DIR), those in the Collector macro and in $(foreach) lists
#      too (./devenv/: the comment stripper the install steps run).
#
# PKG_LICENSE_FILES is the source's own: the tarball has the files it names.
#
# It fails closed: if a change has no anchor to apply to, if the source already
# sets a line the generator adds, or if a line other than a comment still names
# a path relative to ./ afterwards, it prints why and writes nothing. With a
# tarball, every path the Makefile copies from must be in it: each collector
# its Collector calls and BASE_COLLECTORS name, each of MODULE_SUBDIRS, each
# libexec program, and the license files.
#
# Usage:
#   gen-feed-makefile.sh [-o OUT] VERSION
#       Download the v<VERSION> tarball, hash it, and transform the Makefile
#       inside it.
#   gen-feed-makefile.sh [-o OUT] --tarball PATH VERSION
#       The same, from a tarball already on disk.
#   gen-feed-makefile.sh [-o OUT] --hash SHA256 [--source MAKEFILE] VERSION
#       Offline: use SHA256 as PKG_HASH and transform MAKEFILE (default:
#       openwrt/ucode-prometheus-exporter/Makefile in this tree). Nothing
#       checks that the hash matches the tag.
#
# Without -o the Makefile goes to standard output. `make feed-makefile` wraps
# this script; test/feed/feed_makefile_test.sh tests it.

set -eu

NAME=ucode-prometheus-exporter
REPO_URL=https://github.com/m00qek/$NAME
ARCHIVE_URL=$REPO_URL/archive/refs/tags/
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

die() {
	printf 'gen-feed-makefile: %s\n' "$*" >&2
	exit 1
}

usage() {
	sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		die "neither sha256sum nor shasum is installed"
	fi
}

version= tarball= hash= source= out=
while [ $# -gt 0 ]; do
	case $1 in
		--tarball) [ $# -ge 2 ] || usage; tarball=$2; shift 2 ;;
		--hash)    [ $# -ge 2 ] || usage; hash=$2; shift 2 ;;
		--source)  [ $# -ge 2 ] || usage; source=$2; shift 2 ;;
		-o|--output) [ $# -ge 2 ] || usage; out=$2; shift 2 ;;
		-h|--help) usage ;;
		-*) die "unknown option: $1" ;;
		*) [ -z "$version" ] || die "more than one VERSION: $version, $1"; version=$1; shift ;;
	esac
done

[ -n "$version" ] || usage
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' \
	|| die "VERSION must look like 1.2.3 (no leading v): $version"
[ -z "$tarball" ] || [ -z "$hash" ] || die "--tarball and --hash are mutually exclusive"
[ -z "$source" ] || [ -n "$hash" ] \
	|| die "--source needs --hash: with a tarball, the Makefile inside it is the source"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

# The prefix GitHub gives the paths in a tag's tarball: the tag without its v.
prefix=$NAME-$version
makefile=openwrt/$NAME/Makefile

if [ -n "$hash" ]; then
	printf '%s\n' "$hash" | grep -Eq '^[0-9a-f]{64}$' \
		|| die "--hash must be 64 lowercase hex digits: $hash"
	[ -n "$source" ] || source=$SCRIPT_DIR/../../$makefile
	[ -f "$source" ] || die "no such source Makefile: $source"
	cp "$source" "$work/source.mk"
else
	if [ -z "$tarball" ]; then
		url=${ARCHIVE_URL}v$version.tar.gz
		tarball=$work/v$version.tar.gz
		curl -fsSL --retry 3 -o "$tarball" "$url" \
			|| die "could not download $url: is v$version tagged and pushed?"
	fi
	[ -f "$tarball" ] || die "no such tarball: $tarball"
	tar -tzf "$tarball" > "$work/listing" 2>/dev/null \
		|| die "not a gzipped tarball: $tarball"
	grep -qx "$prefix/$makefile" "$work/listing" \
		|| die "$tarball has no $prefix/$makefile: is it the v$version tarball?"
	tar -xzOf "$tarball" "$prefix/$makefile" > "$work/source.mk"
	hash=$(sha256_of "$tarball")
fi

# The source must be the release asked for, so a stale tree or a mistyped
# VERSION cannot pair one release's file list with another's hash.
src_name=$(sed -n 's/^PKG_NAME:=//p' "$work/source.mk")
src_version=$(sed -n 's/^PKG_VERSION:=//p' "$work/source.mk")
[ "$src_name" = "$NAME" ] || die "source PKG_NAME is '$src_name', expected $NAME"
[ "$src_version" = "$version" ] \
	|| die "source PKG_VERSION is '$src_version', expected $version"

LC_ALL=C awk -v hash="$hash" -v archive_url="$ARCHIVE_URL" '
function fail(msg) {
	printf "gen-feed-makefile: %s\n", msg > "/dev/stderr"
	failed = 1
	exit 1
}

# The generator owns these; one already in the source would end up twice.
/^(PKG_SOURCE[A-Z_]*|PKG_HASH|PKG_MIRROR_HASH|PKG_BUILD_DIR)[ \t]*[:?+]?=/ {
	fail("line " NR ": the source already sets " $1 "; the generator adds it")
}

# 1. The source lines, after PKG_RELEASE.
/^PKG_RELEASE:=/ {
	releases++
	print
	print ""
	print "PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz"
	print "PKG_SOURCE_URL:=" archive_url
	print "PKG_SOURCE_URL_FILE:=v$(PKG_VERSION).tar.gz"
	print "PKG_HASH:=" hash
	print "PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)"
	next
}

/^PKG_LICENSE_FILES:=/ { licenses++ }
/^define Package\/[^\/]+$/ { packages++ }
/^\$\(eval \$\(call BuildPackage,/ { builds++ }
/^define Collector$/ { collector_macro++ }
/^\$\(eval \$\(call Collector,/ { collectors++ }

# 2. Paths into the unpacked tarball, after a space or a $(foreach) comma.
{
	for (i = 1; i <= 4; i++) {
		d = i == 1 ? "src" : i == 2 ? "files" : i == 3 ? "luci" : "devenv"
		gsub(" \\./" d "/", " $(PKG_BUILD_DIR)/" d "/")
		gsub(",\\./" d "/", ",$(PKG_BUILD_DIR)/" d "/")
	}
	print
}

END {
	if (failed)
		exit 1
	if (releases != 1)
		fail("expected one PKG_RELEASE:= line, found " releases + 0)
	if (licenses != 1)
		fail("expected one PKG_LICENSE_FILES:= line, found " licenses + 0)
	if (packages < 1)
		fail("found no define Package/<name> block")
	# The Collector and Group macros define and build their packages
	# indented; these are the base package and the LuCI app.
	if (builds != packages)
		fail("found " packages " define Package/<name> blocks but " builds + 0 " BuildPackage calls")
	if (collector_macro != 1 || collectors < 1)
		fail("expected the Collector macro and its calls, found " collector_macro + 0 " and " collectors + 0)
}
' "$work/source.mk" > "$work/feed.mk" || die "refusing to generate the feed Makefile (see above)"

# Nothing may still name a path relative to the package directory: the feed
# has no src/, files/, luci/ or devenv/ next to its Makefile. Comments may.
if grep -nE '(^|[[:space:]=,:])\.\.?/' "$work/feed.mk" | grep -vE '^[0-9]+:[[:space:]]*#' > "$work/relative"; then
	cat "$work/relative" >&2
	die "these lines still use a path relative to ./ (only ./src/, ./files/, ./luci/ and ./devenv/ are rewritten)"
fi

# The paths the Makefile copies from, relative to the tarball's root, one a
# line. A variable is expanded where the Makefile says its value: a plain
# NAME:= at the top, a $(foreach)'s list on its own line, and $(1) in the
# Collector macro, once for each module a Collector call names. Of a path
# that still holds a variable or a glob, its directory stands for it.
paths() {
	LC_ALL=C awk '
	# Each $(NAME) of `s` that `vars` has, replaced by its value.
	function subst(s, vars,   out, i, j, name) {
		out = ""
		while ((i = index(s, "$(")) > 0) {
			j = index(substr(s, i + 2), ")")
			if (j == 0)
				break
			name = substr(s, i + 2, j - 1)
			if (name in vars) {
				out = out substr(s, 1, i - 1) vars[name]
			} else {
				out = out substr(s, 1, i + 1 + j)
			}
			s = substr(s, i + 2 + j)
		}
		return out s
	}

	# The path at the start of `s`: up to a space, a ; or a , or the ) that
	# closes what it is in, a $(...) of its own taken whole.
	function path_at(s,   k, c, depth) {
		depth = 0
		for (k = 1; k <= length(s); k++) {
			c = substr(s, k, 1)
			if (c == "$" && substr(s, k + 1, 1) == "(") {
				depth++
				k++
			} else if (c == ")") {
				if (depth == 0)
					break
				depth--
			} else if (depth == 0 && (c == " " || c == "\t" || c == ";" || c == ",")) {
				break
			}
		}
		return substr(s, 1, k - 1)
	}

	# Prints `p` once for each value of each loop variable it holds, its plain
	# variables expanded; what still holds a variable or a glob, as its
	# directory.
	function expand(p,   name, n, w, k, i, j) {
		for (name in loop) {
			i = index(p, "$(" name ")")
			if (i == 0)
				continue
			n = split(loop[name], w, " ")
			for (k = 1; k <= n; k++)
				expand(substr(p, 1, i - 1) w[k] substr(p, i + length(name) + 3))
			return
		}
		p = subst(p, plain)
		i = index(p, "$(")
		j = index(p, "*")
		if (j > 0 && (i == 0 || j < i))
			i = j
		if (i > 0) {
			p = substr(p, 1, i - 1)
			sub(/[^\/]*$/, "", p)
		}
		sub(/\/+$/, "", p)
		print p
	}

	# First pass: the plain variables, and the modules of the Collector calls.
	NR == FNR {
		if (match($0, /^[A-Za-z_][A-Za-z0-9_]*:=/))
			plain[substr($0, 1, RLENGTH - 2)] = substr($0, RLENGTH + 1)
		if (index($0, "$(eval $(call Collector,") == 1) {
			split(substr($0, 25), a, ",")
			modules = modules " " a[1]
		}
		next
	}

	/^define Collector$/ { in_collector = 1 }
	/^endef$/ { in_collector = 0 }

	{
		split("", loop)
		if (in_collector)
			loop["1"] = modules

		# The loop variables of this line: $(foreach VAR,LIST,...).
		rest = $0
		while ((i = index(rest, "$(foreach ")) > 0) {
			rest = substr(rest, i + 10)
			c1 = index(rest, ",")
			v = substr(rest, 1, c1 - 1)
			rest = substr(rest, c1 + 1)
			c2 = index(rest, ",")
			loop[v] = subst(substr(rest, 1, c2 - 1), plain)
			rest = substr(rest, c2 + 1)
		}

		rest = $0
		while ((i = index(rest, "$(PKG_BUILD_DIR)/")) > 0) {
			rest = substr(rest, i + 17)
			expand(path_at(rest))
		}
	}

	END {
		n = split(plain["PKG_LICENSE_FILES"], w, " ")
		for (k = 1; k <= n; k++)
			print w[k]
	}
	' "$work/feed.mk" "$work/feed.mk" | sort -u
}

# With the tarball at hand, every path the Makefile copies from must be in it.
if [ -f "$work/listing" ]; then
	paths > "$work/paths"
	missing=
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		grep -qxF -e "$prefix/$p" -e "$prefix/$p/" "$work/listing" || missing="$missing $p"
	done < "$work/paths"
	[ -z "$missing" ] || die "the Makefile copies paths the v$version tarball lacks:$missing"
fi

if [ -n "$out" ]; then
	# Write beside the target, then rename, so a failure never leaves half a file.
	tmp_out=$(mktemp "$out.XXXXXX") || die "cannot write next to $out"
	cp "$work/feed.mk" "$tmp_out" && mv "$tmp_out" "$out" || { rm -f "$tmp_out"; die "cannot write $out"; }
else
	cat "$work/feed.mk"
fi
