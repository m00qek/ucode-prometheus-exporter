#!/bin/sh
# usage: feed-check.sh SDK_IMAGE OUT
# Builds the packages as the packages.ucode.dev feed builds them, and checks
# that they hold what `make package` built in bin/ (PKG_FULLVERSION's).
#
# The feed builds from the tarball GitHub serves for a tag, with the Makefile
# gen-feed-makefile.sh makes of it, which installs from $(PKG_BUILD_DIR), where
# the SDK unpacks that tarball. make package builds from this tree, mounted
# where the Makefile reads ./src: a step that only works on a tree already
# there, as a $(wildcard) of the sources, builds here and not in the feed. So
# this builds from `git archive` of the tree, which GitHub's tarball is, in
# OUT, offline, and compares each package's files, modes, hashes, depends and
# scripts with make package's, file timestamps left out.
set -eu

[ $# -eq 2 ] || { sed -n '2p' "$0" >&2; exit 2; }
sdk=$1
cd "$(dirname "$0")/../.."
: "${PKG_FULLVERSION:?PKG_FULLVERSION is the version make package built}"

name=ucode-prometheus-exporter
version=$(sed -n 's/^PKG_VERSION:=//p' openwrt/$name/Makefile)
rm -rf "$2"
mkdir -p "$2/dl" "$2/package" "$2/bin" "$2/dump"
out=$(cd "$2" && pwd)
chmod a+rwx "$out/bin" "$out/dump"

# The tracked files as they are, changes not yet committed included.
tarball=$out/dl/$name-$version.tar.gz
tree=$(git stash create)
git archive --format=tar.gz --prefix="$name-$version/" -o "$tarball" "${tree:-HEAD}"
sh devenv/scripts/gen-feed-makefile.sh --tarball "$tarball" -o "$out/package/Makefile" "$version"

# The SDK builds as its own user, which may not be this one: on a GitHub runner
# it is not.
chmod -R a+rX "$out/package" "$out/dl"

# fakeroot closes every descriptor up to the open-file limit as it starts: see
# the Makefile's package target.
if ! docker run --rm --network none --ulimit nofile=1024:524288 \
	-v "$out/package:/builder/package/$name:ro" \
	-v "$tarball:/builder/dl/$name-$version.tar.gz:ro" \
	-v "$out/bin:/builder/bin" \
	"$sdk" sh -c "make defconfig >/dev/null && make package/$name/compile NO_DEPS=1 CHECK_KEY=0 V=s" \
	>"$out/build.log" 2>&1; then
	tail -20 "$out/build.log" >&2
	echo "feed-check: the feed's build of $name $version failed; its log is $out/build.log" >&2
	exit 1
fi

mkdir -p "$out/feed" "$out/local"
find "$out/bin" -type f \( -name "$name*-$PKG_FULLVERSION.apk" -o -name "luci-app-prometheus-exporter-$PKG_FULLVERSION.apk" \) \
	-exec cp {} "$out/feed/" \;
find bin bin/devkit -maxdepth 1 -type f \( -name "$name*-$PKG_FULLVERSION.apk" -o -name "luci-app-prometheus-exporter-$PKG_FULLVERSION.apk" \) \
	-exec cp {} "$out/local/" \;

feed_names=$(ls "$out/feed")
local_names=$(ls "$out/local")
if [ "$feed_names" != "$local_names" ]; then
	echo "feed-check: the feed builds other packages than make package:" >&2
	printf '%s\n' "$feed_names" >"$out/feed.names"
	printf '%s\n' "$local_names" >"$out/local.names"
	diff "$out/local.names" "$out/feed.names" >&2 || true
	exit 1
fi

# Each package as apk describes it, but its timestamps and the sizes of its
# blocks, which change with them.
chmod -R a+rwX "$out/feed" "$out/local"
docker run --rm --network none -v "$out:/out" "$sdk" sh -c '
	for set in feed local; do
		for p in /out/$set/*.apk; do
			/builder/staging_dir/host/bin/apk adbdump "$p" 2>&1 |
				grep -v -e "mtime:" -e "^# ADB block" -e "^  hashes:" >"/out/dump/$set.$(basename "$p").txt"
		done
	done'

differs=0
for p in $feed_names; do
	if ! diff -u "$out/dump/local.$p.txt" "$out/dump/feed.$p.txt" >"$out/dump/$p.diff"; then
		echo "feed-check: $p differs from make package's:" >&2
		head -20 "$out/dump/$p.diff" >&2
		differs=1
	fi
done
[ "$differs" -eq 0 ] || exit 1
echo "feed-check: the feed builds the $(printf '%s\n' "$feed_names" | wc -l) packages of $name $version as make package does"
