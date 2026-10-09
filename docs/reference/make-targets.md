# Make Targets

Every target runs in Docker, but `feed-makefile`, a shell script with `curl`; nothing is installed on the host. `monitoring-lab` waits for its servers with `curl` on the host. `fixtures` and `bench-device` reach a device over ssh.

---

## Root `Makefile`

### Tests and checks

| Target | Description |
| :--- | :--- |
| `test` | The unit, integration and docs generator tests, with utest, in the OpenWrt image of `OPENWRT_VERSION`. |
| `unit` | `test/unit/` only. |
| `integration` | `test/integration/` only. |
| `watch` | All tests, then again whenever a file under `src/`, `test/`, `files/`, `devenv/scripts/` or `docs/gen/` changes. |
| `lint` | Loads every module on the release's ucode, so a function it lacks fails here; compiles every test, program and handler; `sh -n` every shell script; parses the JSON of `luci/` and the LuCI views (as the function bodies LuCI compiles them into, with quickjs); fails on LuCI code that could turn data into markup (`devenv/scripts/luci-dom-lint.sh`); checks the pinned documentation links (`devenv/scripts/docs-links.sh`, see [Link check](docs-publishing.md#link-check)); fails while a generated reference page is not what `docs-gen` would write; and runs `test/feed/`, the tests of `feed-makefile`'s generator. Then checks that `luci/po/templates/prometheus-exporter.pot` is what `pot` would write. |
| `shell` | A shell in the development image. |
| `image` | Rebuilds the development image, pulling its base again. |

### Packages and the device

| Target | Description |
| :--- | :--- |
| `package` | Builds the apks with the OpenWrt SDK of `OPENWRT_ARCH` and `OPENWRT_VERSION`, into `bin/`, and the devkit's into `bin/devkit/`. |
| `template-package` | Builds the devkit's template collector package, `devkit/template`, with the same SDK, as a package of another tree, against this tree's release of the exporter, into `bin/template/`. |
| `package-check` | `package`, then installs the packages offline in an OpenWrt image that carries their dependencies, scrapes a real uhttpd on loopback, calls the ubus object in a real rpcd, with the base package alone and then with the LuCI app, and checks the files, dependencies and ACL; then installs the devkit, runs the template collector's tests on it from the template's own utest config, and has `collector check` pass the template. |
| `e2e` | `package` and `template-package`, then boots OpenWrt (procd, ubusd, netifd) in a privileged container without network and checks the service in its jail as packages come and go and its config changes, and its ubus object, without LuCI; the template collector's package is installed beside the exporter's, served and removed. |
| `lab` | `package`, then OpenWrt under procd in a privileged container, left running, with every collector package and the LuCI app installed: LuCI on `http://LAB_ADDRESS:LAB_LUCI_PORT/` (root, no password) and `/metrics` on `http://LAB_ADDRESS:LAB_METRICS_PORT/metrics`. `make lab` again starts it afresh with new packages. See [How to use the lab](../how-to/developer/lab.md). |
| `lab-down` | Removes the lab's container. |
| `browser` | `package`, then the Playwright tests of `test/browser/` against LuCI in a container: the built packages, the ubus object in a real rpcd, real collectors, a stand-in for procd and netifd. Results and screenshots in `bin/browser/`. |
| `pot` | Writes `luci/po/templates/prometheus-exporter.pot` with openwrt/luci's scanner. Fails, and writes nothing, when the scanner warns. |
| `fixtures` | Reads the sources of `test/fixtures/SOURCES` from `HOST` over ssh into `test/fixtures/NAME/`. See [How to capture fixtures](../how-to/developer/fixtures.md). |

### Benchmark

| Target | Description |
| :--- | :--- |
| `bench` | Each collector and whole scrapes on the generated worlds, in the package-check image: a table, and `bin/bench/<label>.json`. Checks the scaling and memory budgets of `test/bench/budgets.uc`, and, unconstrained, the time budgets too. |
| `bench-worlds` | Writes the worlds to `bin/bench/worlds/`. |
| `bench-device` | The benchmark on `HOST` over ssh, from its `/tmp`, with its own ucode; nothing is installed and everything copied is removed. |
| `bench-qemu` | `package` and `bench-worlds`, then the benchmark on OpenWrt's malta target, a MIPS 24Kc, little-endian in qemu-system-mipsel or big-endian in qemu-system-mips (`QEMU_ENDIAN`), with the built packages installed from the release's feed. Before the bench, the guest checks what reads data in the CPU's byte order (`devenv/scripts/qemu-checks.uc`), and the target fails if a check does. |
| `bench-src` | With `BENCH_REV`, extracts that revision's `src/` into `bin/bench/rev-<rev>`. `bench` and `bench-device` run it. |

### Monitoring

| Target | Description |
| :--- | :--- |
| `monitoring-check` | Checks `monitoring/`: that every metric family and label its rules, their tests and its dashboards name is in [Metrics](metrics.md) (`devenv/scripts/monitoring-refs.py`, in the docs' mkdocs image); `promtool check rules` and `promtool test rules`; `vmalert -dryRun` and `vmalert-tool unittest` on the same files; `percli lint` of the Perses dashboards against the plugins the Perses image ships; and that the Grafana dashboards take their data source from a variable. Each in its official image, without the network. The metric check and the lint are also shown something they must refuse. |
| `monitoring-lab` | Prometheus, Grafana and Perses on the running lab (`LAB_NAME`), with `monitoring/`'s rules and dashboards: the dashboards applied to Perses with `percli lint --online` and `percli apply`, every panel's queries run through Grafana's and Perses's APIs after `MONITORING_WAIT` seconds, a report in `bin/monitoring/report.txt` and screenshots in `bin/monitoring/screenshots/`. Left running. See [How to use the lab](../how-to/developer/lab.md#watch-it-with-prometheus-grafana-and-perses). |
| `monitoring-lab-down` | Removes `monitoring-lab`'s containers and network. |
| `failure-demo` | `package`, then this exporter and the feed's Lua exporter when what they read breaks, as a Prometheus server (the official image, `prom/prometheus`) scrapes them every 15 s with its 10 s timeout: a hung ubus daemon, a program that never exits, a label that is not UTF-8, each exporter in an unprivileged container of its own; and a conntrack table of `FD_CONNTRACK` connections on QEMU's malta, each exporter booted under procd. Prints a table, kept with the logs and the JSON in `bin/failure-demo/`. Some 25 minutes, with the network; not in CI. See [What happens when a collector breaks](../explanation/when-a-collector-breaks.md#reproduce). |

### Release

| Target | Description |
| :--- | :--- |
| `feed-makefile` | Writes the Makefile of the packages.ucode.dev feed for release `VERSION` to `OUT`, or to standard output: this tree's package Makefile as the `v<VERSION>` tag has it, built from GitHub's tarball of the tag, which it downloads and hashes. See [How to publish a release to the package feed](../how-to/developer/publish-to-feed.md). |

### Documentation

| Target | Description |
| :--- | :--- |
| `docs` | `make -C docs build`. |
| `docs-mike` | `make -C docs build-mike`. |
| `docs-test` | `make -C docs test`. |
| `docs-serve` | `make -C docs serve`. |
| `docs-gen` | Writes the generated reference pages, `docs/reference/collectors.md`, `metrics.md`, `uci-config.md`, `error-codes.md`, `command.md` and `migration.md`, from the code, the fixtures, `docs/gen/notes.uc`, and for `migration.md` `docs/gen/migration.md`, `migration.uc` and `feed-exporters.json`, in the development image. Fails, writing nothing, when the notes contradict the code, or the migration's mapping the feed's exporters or the collectors. See [How to write documentation](../how-to/developer/documentation.md#generated-pages). |
| `feed-inventory` | Writes `docs/gen/feed-exporters.json`, what the feed's Lua and ucode exporters write and how they are packaged, from their sources in openwrt/packages at `FEED_PACKAGES_REF`, which it downloads from GitHub; `docs-gen` writes the migration page from it. With `CHECK=1`, writes nothing and fails when the feed is not what the file says. |

`test`, `unit`, `integration`, `watch`, `lint`, `shell` and `docs-gen` run in the image `ucode-prometheus-exporter-openwrt:<arch>-<version>-<hash>`, built on first use from `devenv/services/openwrt/Dockerfile`; `<hash>` is the Dockerfile's, so worktrees with different Dockerfiles do not overwrite each other's image. The container has no network and sees the checkout read-only; `docs-gen` alone may write, to `docs/reference/`.

### Variables

| Variable | Default | Applies to | Description |
| :--- | :--- | :--- | :--- |
| `OPENWRT_VERSION` | `25.12.5` | all | The OpenWrt release of the images and the SDK. CI also runs `25.12.0`, the API floor. |
| `OPENWRT_ARCH` | `x86_64` | all | The architecture of the images and the SDK. |
| `FILTER` | — | tests, `browser`, `bench`, `bench-device`, `bench-qemu` | Tests: only those whose name matches. Benchmark: a regex of `world/case`. |
| `VERBOSE` | — | tests, `package`, `template-package` | Tests: one line per test. `package`, `template-package`: the SDK's `V=s`. |
| `MODULES` | — | tests | Only these test files or directories. |
| `TEST_TIMEOUT` | `300` | tests | Seconds the whole run may take; past them it is stopped, and the test file it was in is named. |
| `CI` | — | all | Runs containers without a TTY. |
| `HOST` | — | `fixtures`, `bench-device` | An ssh destination. |
| `NAME` | — | `fixtures` | The fixture set to write, `test/fixtures/NAME/`. |
| `LAB_NAME` | `ucode-prometheus-exporter-lab` | `lab`, `lab-down`, `monitoring-lab`, `monitoring-lab-down` | The lab's container. |
| `LAB_ADDRESS` | `127.0.0.1` | `lab` | The host address its ports are published on. |
| `LAB_LUCI_PORT` | `8080` | `lab` | LuCI's port on the host. |
| `LAB_METRICS_PORT` | `9100` | `lab` | `/metrics`' port on the host. |
| `MONITORING_ADDRESS` | `127.0.0.1` | `monitoring-lab` | The host address Prometheus, Grafana and Perses are published on. |
| `PROMETHEUS_PORT` | `9090` | `monitoring-lab` | Prometheus's port on the host. |
| `GRAFANA_PORT` | `3000` | `monitoring-lab` | Grafana's port on the host. |
| `PERSES_PORT` | `8081` | `monitoring-lab` | Perses's port on the host. |
| `MONITORING_WAIT` | `180` | `monitoring-lab` | Seconds of the lab's scrapes before the panels are checked. |
| `BENCH_ARGS` | — | benchmark | Options of `test/bench/bench.uc`: `-r N` runs at least, `-t S` seconds at least. |
| `BENCH_REV` | — | `bench`, `bench-device` | Bench another revision's `src/` with this benchmark. |
| `BENCH_CPUS` | — | `bench` | A share of a CPU, 0.05 at least, as a CFS quota of a 20 ms period. |
| `BENCH_CPUSET` | — | `bench` | The CPUs the container may use. |
| `BENCH_MEMORY` | — | `bench` | The container's memory, without swap. |
| `BENCH_LABEL` | `devenv` and the limits | `bench` | The name of the result. |
| `BENCH_DEVICE_LABEL` | `HOST` | `bench-device` | The name of the result. |
| `QEMU_ENDIAN` | `le` | `bench-qemu` | `le`: malta/le, `mipsel_24kc`, as MT7621-class routers. `be`: malta/be, `mips_24kc`, as ath79-class ones. |
| `QEMU_SHIFT` | `1` | `bench-qemu` | The guest runs at 1000/2^`QEMU_SHIFT` MIPS: 1 is 500, 2 is 250. |
| `QEMU_MEMORY` | `128` | `bench-qemu` | The guest's memory, in MB. |
| `BENCH_QEMU_LABEL` | `qemu-malta-shift<N>`, `qemu-malta-be-shift<N>` big-endian | `bench-qemu` | The name of the result. |
| `FD_SCENARIOS` | all | `failure-demo` | The scenarios to run, of `healthy`, `hung-ubus`, `stuck-nft`, `bad-utf8` and `conntrack`. |
| `FD_SCRAPES` | `8` | `failure-demo` | The scrapes Prometheus makes of each exporter in a scenario. |
| `FD_CONNTRACK` | `20000` | `failure-demo` | The connections of `conntrack`'s table. |
| `FD_QEMU_CPUS` | `0.65` | `failure-demo` | The share of a host CPU `conntrack`'s QEMU gets, without `-icount`, so that the guest's time is Prometheus's: pick the share that makes the guest's loop turn, which it prints, near 9.9 µs, `bench-qemu`'s 500-MIPS 24Kc. |
| `FEED_PACKAGES_REF` | a commit of `openwrt-25.12` | `feed-inventory` | The openwrt/packages commit, or branch, to read the feed's exporters from. |
| `CHECK` | — | `feed-inventory` | Check `docs/gen/feed-exporters.json` against the feed, writing nothing. |
| `VERSION` | — | `feed-makefile` | The release, `X.Y.Z`, without the `v`. |
| `OUT` | — | `feed-makefile` | Where to write the Makefile. |
| `TARBALL` | — | `feed-makefile` | The tag's tarball, already on disk, instead of downloading it. |
| `HASH` | — | `feed-makefile` | Offline: transform this tree's package Makefile, with this sha256 as `PKG_HASH`. |

```sh
make unit FILTER='collectors.wifi' VERBOSE=1
make unit MODULES=test/unit/prometheus_exporter/collectors/wifi_test.uc
make bench FILTER='typical/scrape' BENCH_CPUS=0.35 BENCH_CPUSET=0
```

## `docs/Makefile`

| Target | Description |
| :--- | :--- |
| `build` | Builds the site into `bin/site/` with `mkdocs build --strict`. |
| `build-mike` | The same with the versioned config, `mkdocs.mike.yml`: the mike plugin, the version selector and the outdated-version banner. |
| `test` | Runs `test/docs/`'s shell and Node tests: the docs version, guard, publish and link-check scripts, with a full mike publish to a throwaway local repository, and the `gh-pages` 404 redirect. No network. |
| `publish` | Publishes release `REF` (`vX.Y.Z`, or a `docs/X.Y` branch) to `gh-pages` with `devenv/scripts/docs-publish.sh`, in the image `build-mike` builds in, with the network and the checkout's git credentials. See [Docs publishing](docs-publishing.md). |
| `serve` | Serves the site with live reload on `http://localhost:8000`, or the port in `DOCS_PORT`. `dev` is the same. |
| `clean` | Removes `bin/site/`. |
| `help` | Lists the targets. The default. |

`build` and `serve` run the pinned `squidfunk/mkdocs-material:9.5.17` image as the invoking user. `build-mike`, `test` and `publish` run `ucode-prometheus-exporter-docs:9.5.17`, the same image with the pinned mike of `devenv/services/docs/requirements.txt`, git and Node, built on first use from `devenv/services/docs/Dockerfile`.
