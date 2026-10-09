# How to Publish a Release to the Package Feed

Routers install the exporter, its collector packages, its groups and luci-app-prometheus-exporter from the [packages.ucode.dev](https://github.com/m00qek/packages.ucode.dev) feed. The feed builds them from the release tarball GitHub serves for a tag, with a Makefile generated from `openwrt/ucode-prometheus-exporter/Makefile`. The examples publish `0.2.0`.

## Prerequisites

- The release is tagged and pushed: `v0.2.0`, with `PKG_VERSION:=0.2.0` in `openwrt/ucode-prometheus-exporter/Makefile`, and `CHANGELOG.md`'s `## [0.2.0]` section dated.
- A checkout of packages.ucode.dev next to this one.
- The feed has `ucode-docopt`, which the command line's package, `ucode-prometheus-exporter-cli`, depends on. It does: the feed publishes it for 25.12.

The feed fetches the tarball of `v<PKG_VERSION>`, so a release that only raises `PKG_RELEASE` cannot reach the feed: publish a new version instead.

---

## 1. Generate the feed Makefile

```bash
make feed-makefile VERSION=0.2.0 OUT=../packages.ucode.dev/ucode-prometheus-exporter/Makefile
```

This downloads the `v0.2.0` tarball, hashes it, and writes the Makefile. If it refuses, it names the line of `openwrt/ucode-prometheus-exporter/Makefile` it does not know how to transform, or the paths the Makefile copies that the tarball lacks: every collector the `Collector` calls and `BASE_COLLECTORS` name, each directory of `MODULE_SUBDIRS`, the programs of `libexec/` and the license files.

`TARBALL=<path>` uses a tarball already on disk instead of downloading it; `HASH=<sha256>` transforms this tree's Makefile with that hash, offline, and checks nothing against a tag.

## 2. Commit it to the feed

In packages.ucode.dev, commit `ucode-prometheus-exporter/Makefile` and push it to `main`. Do not edit the file there: the feed's workflow regenerates it from the tag and fails if the two differ.

The workflow then builds every package with the OpenWrt 25.12 SDK, signs them into `25.12/noarch/`, and adds them to every architecture's index. The first release to reach the feed needs that workflow, a copy of the feed's `wgpathd` one: it runs this repository's `devenv/scripts/gen-feed-makefile.sh` from the tag, and expects the 35 packages of 0.2.0, the base package, 29 collectors, 4 groups and the LuCI app.

## 3. Check the feed

On a router with the feed configured:

```bash
apk update
apk info -a ucode-prometheus-exporter | head -3
```

The version shown is `0.2.0-r<PKG_RELEASE>`. To upgrade a router to it, see [Upgrading the exporter](../upgrade.md).
