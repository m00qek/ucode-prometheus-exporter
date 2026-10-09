#!/bin/sh
# gen-feed-makefile.sh: the packages.ucode.dev Makefile for the exporter, and
# what it refuses. Runs offline in the openwrt container (make lint).

TOP=$(cd "$(dirname "$0")/../.." && pwd)
GEN=$TOP/devenv/scripts/gen-feed-makefile.sh
NAME=ucode-prometheus-exporter
SOURCE=$TOP/openwrt/$NAME/Makefile
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
failures=0

pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; failures=$((failures + 1)); }

check() {
	desc=$1
	shift
	if out=$("$@" 2>&1); then
		pass "$desc"
	else
		fail "$desc"
		[ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/     /'
	fi
}

# refuses PATTERN COMMAND...: fails, with PATTERN (a grep -E) in its stderr.
refuses() {
	pattern=$1
	shift
	err=$("$@" 2>&1 >/dev/null) && { echo "succeeded"; return 1; }
	printf '%s\n' "$err" | grep -Eq "$pattern" || { echo "got: $err"; return 1; }
}

HASH=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
VERSION=$(sed -n 's/^PKG_VERSION:=//p' "$SOURCE")
gen() { sh "$GEN" "$@"; }

# The feed Makefile is the in-tree one plus the source lines and paths into
# the unpacked tarball, and nothing else.
feed_matches_tree() {
	gen --hash "$HASH" "$VERSION" > "$TMP/feed.mk" || return 1
	sed -e 's#\([ ,]\)\$(PKG_BUILD_DIR)/src/#\1./src/#g' \
		-e 's#\([ ,]\)\$(PKG_BUILD_DIR)/files/#\1./files/#g' \
		-e 's#\([ ,]\)\$(PKG_BUILD_DIR)/luci/#\1./luci/#g' "$TMP/feed.mk" \
		| grep -vE '^(PKG_SOURCE|PKG_SOURCE_URL|PKG_SOURCE_URL_FILE|PKG_HASH|PKG_BUILD_DIR):=' > "$TMP/back.mk"
	release=$(grep -n '^PKG_RELEASE:=' "$SOURCE" | cut -d: -f1)
	# One blank line is added before the source lines.
	[ "$(awk -v blank=$((release + 1)) 'NR == blank && $0 == "" { next } { print }' "$TMP/back.mk")" = "$(cat "$SOURCE")" ] \
		|| { echo "differs from the in-tree Makefile beyond the added lines and paths"; return 1; }
	grep -qx "PKG_HASH:=$HASH" "$TMP/feed.mk" || { echo "no PKG_HASH"; return 1; }
	grep -qx 'PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz' "$TMP/feed.mk" || { echo "no PKG_SOURCE"; return 1; }
	grep -qx "PKG_SOURCE_URL:=https://github.com/m00qek/$NAME/archive/refs/tags/" "$TMP/feed.mk" || { echo "no PKG_SOURCE_URL"; return 1; }
	grep -qx 'PKG_SOURCE_URL_FILE:=v$(PKG_VERSION).tar.gz' "$TMP/feed.mk" || { echo "no PKG_SOURCE_URL_FILE"; return 1; }
	grep -qx 'PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)' "$TMP/feed.mk" || { echo "no PKG_BUILD_DIR"; return 1; }
	grep -qx 'PKG_LICENSE_FILES:=LICENSE NOTICE' "$TMP/feed.mk" || { echo "PKG_LICENSE_FILES is not the source's"; return 1; }
}
check "the feed Makefile is the in-tree one plus the source lines and tarball paths" feed_matches_tree

# The Collector macro's path and a $(foreach) list's, after a comma.
macros_point_into_the_tarball() {
	gen --hash "$HASH" "$VERSION" > "$TMP/feed.mk" || return 1
	grep -qF '$$(INSTALL_DATA) $(PKG_BUILD_DIR)/src/prometheus_exporter/collectors/$(1).uc' "$TMP/feed.mk" \
		|| { echo "the Collector macro's path"; return 1; }
	grep -qF ',$(PKG_BUILD_DIR)/files/usr/libexec/$(SERVICE)/$(f).uc)' "$TMP/feed.mk" \
		|| { echo "the libexec programs' \$(foreach)"; return 1; }
}
check "the Collector macro and \$(foreach) lists point into the tarball" macros_point_into_the_tarball

# A source Makefile that differs from the in-tree one by SED_EXPR.
variant() {
	sed "$1" "$SOURCE" > "$TMP/variant.mk"
}

check "a VERSION that is not the source's is refused" \
	refuses "source PKG_VERSION is '$VERSION', expected 9.9.9" gen --hash "$HASH" 9.9.9

variant 's/^PKG_RELEASE:=.*/&\nPKG_HASH:=skip/'
check "a source that already sets PKG_HASH is refused" \
	refuses "already sets PKG_HASH" gen --hash "$HASH" --source "$TMP/variant.mk" "$VERSION"

variant '/^PKG_LICENSE_FILES:=/d'
check "a source without PKG_LICENSE_FILES is refused" \
	refuses "one PKG_LICENSE_FILES:= line, found 0" gen --hash "$HASH" --source "$TMP/variant.mk" "$VERSION"

variant 's|^\t\$(INSTALL_DIR) \$(1)/etc/config$|&\n\t$(CP) ./extra/thing $(1)/|'
check "a copy from a directory the generator does not rewrite is refused" \
	refuses "still use a path relative" gen --hash "$HASH" --source "$TMP/variant.mk" "$VERSION"

variant '/^\$(eval \$(call BuildPackage,\$(LUCI_APP)))/d'
check "a package without its BuildPackage call is refused" \
	refuses "([0-9]+) define Package/<name> blocks but ([0-9]+) BuildPackage" gen --hash "$HASH" --source "$TMP/variant.mk" "$VERSION"

check "a bad hash is refused" refuses "64 lowercase hex" gen --hash abc "$VERSION"
check "a VERSION with a leading v is refused" refuses "no leading v" gen --hash "$HASH" "v$VERSION"

# A tarball shaped like GitHub's for the tag: everything under
# <name>-<version>/, but for the paths given.
tarball() {
	root=$TMP/tar/$NAME-$VERSION
	rm -rf "$TMP/tar"
	mkdir -p "$root/openwrt/$NAME"
	cp "$SOURCE" "$root/openwrt/$NAME/"
	for d in src files luci LICENSE NOTICE; do
		cp -R "$TOP/$d" "$root/$d"
	done
	for p in "$@"; do
		rm -rf "${root:?}/$p"
	done
	(cd "$TMP/tar" && tar -czf "$TMP/v$VERSION.tar.gz" "$NAME-$VERSION")
}

from_tarball_hashes_it() {
	tarball
	gen --tarball "$TMP/v$VERSION.tar.gz" -o "$TMP/out.mk" "$VERSION" || return 1
	sum=$(sha256sum "$TMP/v$VERSION.tar.gz" | cut -d' ' -f1)
	grep -qx "PKG_HASH:=$sum" "$TMP/out.mk" || { echo "PKG_HASH is not the tarball's sha256"; return 1; }
}
check "from a tarball, PKG_HASH is its sha256" from_tarball_hashes_it

no_output_on_failure() {
	tarball luci
	rm -f "$TMP/out.mk"
	refuses "tarball lacks: luci/htdocs luci/root" gen --tarball "$TMP/v$VERSION.tar.gz" -o "$TMP/out.mk" "$VERSION" || return 1
	[ ! -e "$TMP/out.mk" ] || { echo "wrote $TMP/out.mk anyway"; return 1; }
}
check "a tarball without the copied paths is refused, and nothing is written" no_output_on_failure

# What the Makefile names through a variable is in the tarball too: a
# collector a Collector call names ($(1) in the macro), a base collector
# ($(c)), a module subdirectory ($(d)), a libexec program ($(f) and
# $(SERVICE)), and a license file.
lacks() {
	tarball "$1"
	refuses "tarball lacks: $1\$" gen --tarball "$TMP/v$VERSION.tar.gz" "$VERSION"
}
check "a tarball without a packaged collector is refused" lacks src/prometheus_exporter/collectors/sockstat.uc
check "a tarball without a base collector is refused" lacks src/prometheus_exporter/collectors/loadavg.uc
check "a tarball without a module subdirectory is refused" lacks src/prometheus_exporter/deps
check "a tarball without a libexec program is refused" lacks files/usr/libexec/prometheus-exporter/probe.uc
check "a tarball without a license file is refused" lacks NOTICE

exit $((failures > 0))
