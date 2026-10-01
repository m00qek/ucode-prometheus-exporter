# Make Targets

Every target runs in Docker; nothing is installed on the host. `fixtures` and `bench-device` reach a device over ssh.

---

## Root `Makefile`

### Tests and checks

| Target | Description |
| :--- | :--- |
| `test` | The unit, integration and docs generator tests, with utest, in the OpenWrt image of `OPENWRT_VERSION`. |
| `unit` | `test/unit/` only. |
| `integration` | `test/integration/` only. |
| `watch` | All tests, then again whenever a file under `src/`, `test/`, `files/`, `devenv/scripts/` or `docs/gen/` changes. |
| `lint` | Loads every module on the release's ucode, so a function it lacks fails here; compiles every test, program and handler; `sh -n` every shell script; parses the JSON of `luci/` and the LuCI views (as the function bodies LuCI compiles them into, with quickjs); fails on LuCI code that could turn data into markup (`devenv/scripts/luci-dom-lint.sh`); checks the pinned documentation links (`devenv/scripts/docs-links.sh`, see [Link check](docs-publishing.md#link-check)); and fails while a generated reference page is not what `docs-gen` would write. Then checks that `luci/po/templates/prometheus-exporter.pot` is what `pot` would write. |
| `shell` | A shell in the development image. |
| `image` | Rebuilds the development image, pulling its base again. |

### Packages and the device

| Target | Description |
| :--- | :--- |
| `package` | Builds the apks with the OpenWrt SDK of `OPENWRT_ARCH` and `OPENWRT_VERSION`, into `bin/`. |
| `package-check` | `package`, then installs the packages offline in an OpenWrt image that carries their dependencies, scrapes a real uhttpd on loopback, calls the ubus object in a real rpcd, with the base package alone and then with the LuCI app, and checks the files, dependencies and ACL. |
| `e2e` | `package`, then boots OpenWrt (procd, ubusd, netifd) in a privileged container without network and checks the service in its jail as packages come and go and its config changes, and its ubus object, without LuCI. |
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
| `bench-qemu` | `package` and `bench-worlds`, then the benchmark on OpenWrt's malta target in qemu-system-mipsel, a MIPS 24Kc, with the built packages installed from the release's feed. |
| `bench-src` | With `BENCH_REV`, extracts that revision's `src/` into `bin/bench/rev-<rev>`. `bench` and `bench-device` run it. |

### Documentation

| Target | Description |
| :--- | :--- |
| `docs` | `make -C docs build`. |
| `docs-mike` | `make -C docs build-mike`. |
| `docs-test` | `make -C docs test`. |
| `docs-serve` | `make -C docs serve`. |
| `docs-gen` | Writes the generated reference pages, `docs/reference/collectors.md`, `metrics.md`, `uci-config.md` and `error-codes.md`, from the code, the fixtures and `docs/gen/notes.uc`, in the development image. Fails, writing nothing, when the notes contradict the code. See [How to write documentation](../how-to/developer/documentation.md#generated-pages). |

`test`, `unit`, `integration`, `watch`, `lint`, `shell` and `docs-gen` run in the image `ucode-prometheus-exporter-openwrt:<arch>-<version>-<hash>`, built on first use from `devenv/services/openwrt/Dockerfile`; `<hash>` is the Dockerfile's, so worktrees with different Dockerfiles do not overwrite each other's image. The container has no network and sees the checkout read-only; `docs-gen` alone may write, to `docs/reference/`.

### Variables

| Variable | Default | Applies to | Description |
| :--- | :--- | :--- | :--- |
| `OPENWRT_VERSION` | `25.12.5` | all | The OpenWrt release of the images and the SDK. CI also runs `25.12.0`, the API floor. |
| `OPENWRT_ARCH` | `x86_64` | all | The architecture of the images and the SDK. |
| `FILTER` | — | tests, `browser`, `bench`, `bench-device`, `bench-qemu` | Tests: only those whose name matches. Benchmark: a regex of `world/case`. |
| `VERBOSE` | — | tests, `package` | Tests: one line per test. `package`: the SDK's `V=s`. |
| `MODULES` | — | tests | Only these test files or directories. |
| `CI` | — | all | Runs containers without a TTY. |
| `HOST` | — | `fixtures`, `bench-device` | An ssh destination. |
| `NAME` | — | `fixtures` | The fixture set to write, `test/fixtures/NAME/`. |
| `LAB_NAME` | `ucode-prometheus-exporter-lab` | `lab`, `lab-down` | The lab's container. |
| `LAB_ADDRESS` | `127.0.0.1` | `lab` | The host address its ports are published on. |
| `LAB_LUCI_PORT` | `8080` | `lab` | LuCI's port on the host. |
| `LAB_METRICS_PORT` | `9100` | `lab` | `/metrics`' port on the host. |
| `BENCH_ARGS` | — | benchmark | Options of `test/bench/bench.uc`: `-r N` runs at least, `-t S` seconds at least. |
| `BENCH_REV` | — | `bench`, `bench-device` | Bench another revision's `src/` with this benchmark. |
| `BENCH_CPUS` | — | `bench` | A share of a CPU, 0.05 at least, as a CFS quota of a 20 ms period. |
| `BENCH_CPUSET` | — | `bench` | The CPUs the container may use. |
| `BENCH_MEMORY` | — | `bench` | The container's memory, without swap. |
| `BENCH_LABEL` | `devenv` and the limits | `bench` | The name of the result. |
| `BENCH_DEVICE_LABEL` | `HOST` | `bench-device` | The name of the result. |
| `QEMU_SHIFT` | `1` | `bench-qemu` | The guest runs at 1000/2^`QEMU_SHIFT` MIPS: 1 is 500, 2 is 250. |
| `QEMU_MEMORY` | `128` | `bench-qemu` | The guest's memory, in MB. |
| `BENCH_QEMU_LABEL` | `qemu-malta-shift<N>` | `bench-qemu` | The name of the result. |

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
| `serve` | Serves the site with live reload on `http://localhost:8000`, or the port in `DOCS_PORT`. `dev` is the same. |
| `clean` | Removes `bin/site/`. |
| `help` | Lists the targets. The default. |

`build` and `serve` run the pinned `squidfunk/mkdocs-material:9.5.17` image as the invoking user. `build-mike` and `test` run `ucode-prometheus-exporter-docs:9.5.17`, the same image with the pinned mike of `devenv/services/docs/requirements.txt`, git and Node, built on first use from `devenv/services/docs/Dockerfile`.
