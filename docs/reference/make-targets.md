# Make Targets

Every target runs in Docker, except `feed-makefile`, a shell script that uses `curl`, and the part of `feed-check` that makes the tarball, with `git archive`. Nothing is installed on the host. `monitoring-lab` waits for its servers with `curl` on the host. `fixtures` and `bench-device` reach a device over ssh.

---

## Root `Makefile`

### Tests and checks

| Target | Description |
| :--- | :--- |
| `test` | Runs the unit, integration and docs generator tests, with utest, in the OpenWrt image of `OPENWRT_VERSION`. Unless `FILTER` or `MODULES` narrows the run, it first runs the strip check (`devenv/scripts/strip-check.sh`): the comment stripper's tests, and every file the packages install, stripped as the build strips it. Each ucode file must compile to the same stripped bytecode as its source. |
| `unit` | `test/unit/` only, with the strip check. |
| `integration` | `test/integration/` only. |
| `watch` | All tests, then again whenever a file under `src/`, `test/`, `files/`, `devenv/scripts/` or `docs/gen/` changes. |
| `lint` | Loads every module on the release's ucode, so a function that ucode lacks fails here. Compiles every test, program and handler, and runs `sh -n` on every shell script. Parses the JSON of `luci/`, and the LuCI views as the function bodies LuCI compiles them into, with quickjs. Fails on LuCI code that could turn data into markup (`devenv/scripts/luci-dom-lint.sh`). Checks the pinned documentation links (`devenv/scripts/docs-links.sh`, see [Link check](docs-publishing.md#link-check)). Fails while a generated reference page is not what `docs-gen` would write. Runs `test/feed/`, the tests of `feed-makefile`'s generator. Then checks that `luci/po/templates/prometheus-exporter.pot` is what `pot` would write. |
| `same-code` | Checks that the sources differ from `REV`'s (`main` by default) only in comments and blank lines. Each ucode file of `src/` and `files/` that differs must compile to the same stripped bytecode, and each JavaScript file of `luci/` must give esbuild the same tokens. `FILES` narrows the paths. Changes nothing (`devenv/scripts/same-code.sh`). |
| `shell` | A shell in the development image. |
| `image` | Rebuilds the development image, pulling its base again. |

### Packages and the device

| Target | Description |
| :--- | :--- |
| `package` | Builds the apks with the OpenWrt SDK of `OPENWRT_ARCH` and `OPENWRT_VERSION`, into `bin/`, and the devkit's into `bin/devkit/`. It strips every comment from the ucode and JavaScript files the packages install, keeping a newline for each line of a comment (`devenv/scripts/strip-comments.py`, on the SDK's Python). |
| `template-package` | Builds the devkit's template collector package, `devkit/template`, with the same SDK, into `bin/template/`. It builds it as a package of another tree, against this tree's release of the exporter. |
| `package-check` | Runs `package`, then installs the packages offline in an OpenWrt image that carries their dependencies. It scrapes a real uhttpd on loopback, and calls the ubus object in a real rpcd, first with the base package alone, then with the LuCI app. It checks the files, the dependencies and the ACL, and that each installed ucode file compiles to the same stripped bytecode as its source. Then it installs the devkit, runs the template collector's tests on it from the template's own utest config, and has `collector check` pass the template. |
| `e2e` | Runs `package` and `template-package`, then boots OpenWrt (procd, ubusd, netifd) in a privileged container without network. It checks the service in its jail as packages come and go and its config changes, and checks its ubus object, without LuCI. It installs, serves and removes the template collector's package beside the exporter's. |
| `lab` | Runs `package`, then OpenWrt under procd in a privileged container, left running, with every collector package and the LuCI app installed. LuCI is on `http://LAB_ADDRESS:LAB_LUCI_PORT/` (root, no password), and `/metrics` on `http://LAB_ADDRESS:LAB_METRICS_PORT/metrics`. `make lab` again starts it afresh with new packages. See [How to use the lab](../how-to/developer/lab.md). |
| `lab-down` | Removes the lab's container. |
| `browser` | Runs `package`, then the Playwright tests of `test/browser/` against LuCI in a container, with the built packages, the ubus object in a real rpcd, real collectors, and a stand-in for procd and netifd. It also checks, with esbuild, that the app's JavaScript as LuCI serves it has its sources' tokens. Results and screenshots go to `bin/browser/`. |
| `pot` | Writes `luci/po/templates/prometheus-exporter.pot` with openwrt/luci's scanner. Fails, and writes nothing, when the scanner warns. |
| `fixtures` | Reads the sources of `test/fixtures/SOURCES` from `HOST` over ssh into `test/fixtures/NAME/`. See [How to capture fixtures](../how-to/developer/fixtures.md). |

### Benchmark

| Target | Description |
| :--- | :--- |
| `bench` | Runs each collector, and whole scrapes, on the generated worlds, in the package-check image. Prints a table, and writes `bin/bench/<label>.json`. Checks the scaling, memory, turn and request budgets of `test/bench/budgets.uc`, and, when unconstrained, the time budgets too. |
| `bench-worlds` | Writes the worlds to `bin/bench/worlds/`. |
| `bench-device` | Runs the benchmark on `HOST` over ssh, from its `/tmp`, with its own ucode. It installs nothing, and removes everything it copied. |
| `bench-qemu` | Runs `package` and `bench-worlds`, then the benchmark on OpenWrt's malta target, a MIPS 24Kc, with the built packages installed from the release's feed. The guest is little-endian in qemu-system-mipsel, or big-endian in qemu-system-mips (`QEMU_ENDIAN`). Before the bench, the guest checks the code that reads data in the CPU's byte order (`devenv/scripts/qemu-checks.uc`), and the target fails if a check does. |
| `bench-src` | With `BENCH_REV`, extracts that revision's `src/` into `bin/bench/rev-<rev>`. `bench` and `bench-device` run it. |

### Monitoring

| Target | Description |
| :--- | :--- |
| `monitoring-check` | Checks `monitoring/`, each tool in its official image, without the network:<br><br>- every metric family and label that its rules, their tests and its dashboards name is in [Metrics](metrics.md) (`devenv/scripts/monitoring-refs.py`, in the docs' mkdocs image);<br>- `promtool check rules` and `promtool test rules`;<br>- `vmalert -dryRun` and `vmalert-tool unittest` on the same files;<br>- `percli lint` of the Perses dashboards against the plugins the Perses image ships;<br>- the Grafana dashboards take their data source from a variable;<br>- no rule matches a `job` or `instance` by name, and no dashboard matches them except by its variables, unless the rule says `monitoring-check: allow-target-matcher`.<br><br>The metric check and the lint are also given input they must refuse. |
| `monitoring-lab` | Runs Prometheus, Grafana and Perses on the running lab (`LAB_NAME`), with `monitoring/`'s rules and dashboards, and leaves them running. It applies the dashboards to Perses with `percli lint --online` and `percli apply`. After `MONITORING_WAIT` seconds, it runs every panel's queries through Grafana's and Perses's APIs. It writes a report to `bin/monitoring/report.txt` and screenshots to `bin/monitoring/screenshots/`. See [How to use the lab](../how-to/developer/lab.md#watch-it-with-prometheus-grafana-and-perses). |
| `monitoring-lab-down` | Removes `monitoring-lab`'s containers and network. |
| `luci-screenshots` | Runs `lab` as a lab of its own (`SCREENSHOTS_LAB`, on ports `SCREENSHOTS_LUCI_PORT` 18080 and `SCREENSHOTS_METRICS_PORT` 19100). Takes the LuCI app's screenshots for the docs, `docs/how-to/img/luci-*.png`, with Playwright in the browser tests' image, and shrinks them with pngquant. Removes the lab afterwards. See `devenv/scripts/luci-screenshots.sh`. |
| `failure-demo` | Runs `package`, then shows this exporter and the feed's Lua exporter when what they read breaks. A Prometheus server (the official image, `prom/prometheus`) scrapes them every 15 s with its 10 s timeout. The scenarios are a hung ubus daemon, a program that never exits, and a label that is not UTF-8, each exporter in an unprivileged container of its own; and a conntrack table of `FD_CONNTRACK` connections on QEMU's malta, each exporter booted under procd. Prints a table, and keeps it with the logs and the JSON in `bin/failure-demo/`. Takes some 25 minutes, with the network; not run in CI. See [What happens when a collector breaks](../explanation/when-a-collector-breaks.md#reproduce). |

### Release

| Target | Description |
| :--- | :--- |
| `feed-makefile` | Writes the Makefile of the packages.ucode.dev feed for release `VERSION` to `OUT`, or to standard output. The Makefile is this tree's package Makefile as the `v<VERSION>` tag has it, set to build from GitHub's tarball of the tag, which the target downloads and hashes. See [How to publish a release to the package feed](../how-to/developer/publish-to-feed.md). |
| `feed-check` | Builds the packages as the feed does, offline: from a `git archive` tarball of this tree, changes not yet committed included, with the Makefile `feed-makefile` makes of it, in the SDK. Fails when that build fails, or when a package's files, modes, hashes, dependencies or scripts differ from what `package` built. Runs `package` first, and leaves its build in `bin/feed`. See `devenv/scripts/feed-check.sh`. |

### Documentation

| Target | Description |
| :--- | :--- |
| `docs` | `make -C docs build`. |
| `docs-mike` | `make -C docs build-mike`. |
| `docs-test` | `make -C docs test`. |
| `docs-serve` | `make -C docs serve`. |
| `docs-gen` | Writes the generated reference pages, `docs/reference/collectors.md`, `metrics.md`, `uci-config.md`, `error-codes.md`, `command.md` and `migration.md`, in the development image. It writes them from the code, the fixtures and `docs/gen/notes.uc`, and `migration.md` also from `docs/gen/migration.md`, `migration.uc` and `feed-exporters.json`. It fails, writing nothing, when the notes contradict the code, or when the migration's mapping contradicts the feed's exporters or the collectors. See [How to write documentation](../how-to/developer/documentation.md#generated-pages). |
| `feed-inventory` | Writes `docs/gen/feed-exporters.json`: what the feed's Lua and ucode exporters write, and how they are packaged. It reads their sources in openwrt/packages at `FEED_PACKAGES_REF`, which it downloads from GitHub. `docs-gen` writes the migration page from this file. With `CHECK=1`, it writes nothing, and fails when the feed is not what the file says. |

`test`, `unit`, `integration`, `watch`, `lint`, `shell` and `docs-gen` run in the image `ucode-prometheus-exporter-openwrt:<arch>-<version>-<hash>`, built on first use from `devenv/services/openwrt/Dockerfile`. `<hash>` is the Dockerfile's hash, so worktrees with different Dockerfiles do not overwrite each other's image. The container has no network, and sees the checkout read-only. Only `docs-gen` may write, and only to `docs/reference/`.

### Variables

| Variable | Default | Applies to | Description |
| :--- | :--- | :--- | :--- |
| `OPENWRT_VERSION` | `25.12.5` | all | The OpenWrt release of the images and the SDK. CI also runs `25.12.0`, the API floor. |
| `OPENWRT_ARCH` | `x86_64` | all | The architecture of the images and the SDK. |
| `FILTER` | — | tests, `browser`, `bench`, `bench-device`, `bench-qemu` | Tests: only those whose name matches. Benchmark: a regex of `world/case`. |
| `VERBOSE` | — | tests, `package`, `template-package` | Tests: one line per test. `package`, `template-package`: the SDK's `V=s`. |
| `MODULES` | — | tests | Only these test files or directories. |
| `TEST_TIMEOUT` | `300` | tests | Seconds the whole run may take. Past them, the run is stopped, and the test file it was in is named. |
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
| `FD_QEMU_CPUS` | `0.65` | `failure-demo` | The share of a host CPU that `conntrack`'s QEMU gets. It runs without `-icount`, so that the guest's time is Prometheus's. Pick the share that makes the guest's loop turn near 9.9 µs, `bench-qemu`'s 500-MIPS 24Kc; the guest prints its turn. |
| `FEED_PACKAGES_REF` | a commit of `openwrt-25.12` | `feed-inventory` | The openwrt/packages commit, or branch, to read the feed's exporters from. |
| `CHECK` | — | `feed-inventory` | Check `docs/gen/feed-exporters.json` against the feed, writing nothing. |
| `VERSION` | — | `feed-makefile` | The release, `X.Y.Z`, without the `v`. |
| `OUT` | — | `feed-makefile` | Where to write the Makefile. |
| `TARBALL` | — | `feed-makefile` | The tag's tarball, already on disk, instead of downloading it. |
| `HASH` | — | `feed-makefile` | Offline: transform this tree's package Makefile, with this sha256 as `PKG_HASH`. |

```sh
make unit FILTER='collectors.wifi' VERBOSE=1
make unit MODULES=test/unit/prometheus/collectors/wifi_test.uc
make bench FILTER='typical/scrape' BENCH_CPUS=0.35 BENCH_CPUSET=0
```

## `docs/Makefile`

| Target | Description |
| :--- | :--- |
| `build` | Builds the site into `bin/site/` with `mkdocs build --strict`. |
| `build-mike` | The same with the versioned config, `mkdocs.mike.yml`: the mike plugin, the version selector and the outdated-version banner. |
| `test` | Runs `test/docs/`'s shell and Node tests: the docs version, guard, publish and link-check scripts, with a full mike publish to a throwaway local repository, and the `gh-pages` 404 redirect. No network. |
| `publish` | Publishes release `REF` (`vX.Y.Z`, or a `docs/X.Y` branch) to `gh-pages` with `devenv/scripts/docs-publish.sh`. It runs in the image `build-mike` builds in, with the network and the checkout's git credentials. See [Docs publishing](docs-publishing.md). |
| `serve` | Serves the site with live reload on `http://localhost:8000`, or the port in `DOCS_PORT`. `dev` is the same. |
| `clean` | Removes `bin/site/`. |
| `help` | Lists the targets. The default. |

`build` and `serve` run the pinned `squidfunk/mkdocs-material:9.5.17` image as the invoking user. `build-mike`, `test` and `publish` run `ucode-prometheus-exporter-docs:9.5.17`: the same image with git, Node, and the pinned mike of `devenv/services/docs/requirements.txt`. It is built on first use from `devenv/services/docs/Dockerfile`.
