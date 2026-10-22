# How to Publish a Release to the Package Feed

Routers install the exporter, its collector packages, its groups and luci-app-prometheus-exporter from the [packages.ucode.dev](https://github.com/m00qek/packages.ucode.dev) feed. The feed builds them from the release tarball GitHub serves for a tag, with a Makefile generated from `openwrt/ucode-prometheus-exporter/Makefile`. The examples publish `0.3.1`.

## Prerequisites

- The release is tagged and pushed: `v0.3.1`, with `PKG_VERSION:=0.3.1` in `openwrt/ucode-prometheus-exporter/Makefile`, and `CHANGELOG.md`'s `## [0.3.1]` section dated.
- `make feed-check` passed on the tagged commit, as CI's `feed` job runs it. It builds the packages from a tarball of the commit, as the feed does. The feed could not build 0.3.0, whose base package listed its modules before the SDK had unpacked the tarball.
- A checkout of packages.ucode.dev next to this one.
- The feed has `ucode-docopt`, which the command line's package, `ucode-prometheus-exporter-cli`, depends on, and `ucode-utest`, which the devkit depends on. The feed already publishes both for 25.12.

The feed fetches the tarball of `v<PKG_VERSION>`. So a release that only raises `PKG_RELEASE` cannot reach the feed: publish a new version instead.

---

## 1. Generate the feed Makefile

```bash
make feed-makefile VERSION=0.3.1 OUT=../packages.ucode.dev/ucode-prometheus-exporter/Makefile
```

This downloads the `v0.3.1` tarball, hashes it, and writes the Makefile. If it refuses, it names one of these:

- the line of `openwrt/ucode-prometheus-exporter/Makefile` it does not know how to transform
- the paths the Makefile copies that the tarball lacks: every collector that the `Collector` calls and `BASE_COLLECTORS` name, each directory of `MODULE_SUBDIRS`, the programs of `libexec/`, and the license files

`TARBALL=<path>` uses a tarball already on disk instead of downloading it. `HASH=<sha256>` transforms this tree's Makefile with that hash, offline, and checks nothing against a tag.

## 2. Commit it to the feed

In packages.ucode.dev, commit `ucode-prometheus-exporter/Makefile` and push it to `main`. Do not edit the file there: the feed's workflow regenerates it from the tag, and fails if the two differ.

The feed's workflow, `.github/workflows/ucode-prometheus-exporter.yml`, then:

- regenerates the Makefile with this repository's `devenv/scripts/gen-feed-makefile.sh`, from the tag, and fails if it differs;
- builds every package with the OpenWrt 25.12 SDK, and fails unless there is one for each of the Makefile's `BuildPackage`, `Collector` and `Group` calls: 41 in 0.3.1, the base package, its command line, 33 collectors, 4 groups, the devkit and the LuCI app;
- on `main`, signs them into `25.12/noarch/`, and adds them to every architecture's index.

A pull request runs the first two.

## 3. Check the feed

On a router with the feed configured:

```bash
apk update
apk info -a ucode-prometheus-exporter | head -3
```

The version shown is `0.3.1-r<PKG_RELEASE>`. To upgrade a router to it, see [Upgrading the exporter](../upgrade.md).
